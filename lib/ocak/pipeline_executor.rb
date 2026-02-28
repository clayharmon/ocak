# frozen_string_literal: true

require 'open3'
require_relative 'pipeline_state'
require_relative 'verification'
require_relative 'planner'

module Ocak
  class PipelineExecutor
    include Verification
    include Planner

    StepContext = Struct.new(:issue_number, :idx, :role, :result, :state, :logger, :chdir)

    attr_writer :issues

    def initialize(config:, issues: nil)
      @config = config
      @issues = issues
    end

    def run_pipeline(issue_number, logger:, claude:, chdir: nil, skip_steps: [], complexity: 'full')
      chdir ||= @config.project_dir
      logger.info("=== Starting pipeline for issue ##{issue_number} (#{complexity}) ===")

      state = { last_review_output: nil, had_fixes: false, completed_steps: [], total_cost: 0.0,
                complexity: complexity, steps_run: 0, steps_skipped: 0 }
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      post_pipeline_start_comment(issue_number, state)

      failure = run_pipeline_steps(issue_number, state, logger: logger, claude: claude, chdir: chdir,
                                                        skip_steps: skip_steps)
      log_cost_summary(state[:total_cost], logger)
      if failure
        duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time).round
        post_pipeline_summary_comment(issue_number, state, duration, success: false,
                                                                     failed_phase: failure[:phase])
        return failure
      end

      failure = run_final_verification(issue_number, logger: logger, claude: claude, chdir: chdir)
      if failure
        duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time).round
        post_pipeline_summary_comment(issue_number, state, duration, success: false,
                                                                     failed_phase: failure[:phase])
        return failure
      end

      pipeline_state.delete(issue_number)

      duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time).round
      post_pipeline_summary_comment(issue_number, state, duration, success: true)
      logger.info("=== Pipeline complete for issue ##{issue_number} ===")
      { success: true, output: 'Pipeline completed successfully' }
    end

    private

    def run_pipeline_steps(issue_number, state, logger:, claude:, chdir:, skip_steps: [])
      @config.steps.each_with_index do |step, idx|
        step = symbolize(step)
        role = step[:role].to_s

        if skip_steps.include?(idx)
          logger.info("Skipping #{role} (already completed)")
          next
        end

        reason = skip_reason(step, state)
        if reason
          logger.info("Skipping #{role} \u2014 #{reason}")
          post_step_comment(issue_number, "\u{23ED}\u{FE0F} **Skipping #{role}** \u2014 #{reason}")
          state[:steps_skipped] += 1
          next
        end

        result = execute_step(step, issue_number, state[:last_review_output], logger: logger, claude: claude,
                                                                              chdir: chdir)
        ctx = StepContext.new(issue_number, idx, role, result, state, logger, chdir)
        failure = record_step_result(ctx)
        return failure if failure
      end
      nil
    end

    def execute_step(step, issue_number, review_output, logger:, claude:, chdir:)
      agent = step[:agent].to_s
      role = step[:role].to_s
      logger.info("--- Phase: #{role} (#{agent}) ---")
      post_step_comment(issue_number, "\u{1F504} **Phase: #{role}** (#{agent})")
      prompt = build_step_prompt(role, issue_number, review_output)
      claude.run_agent(agent.tr('_', '-'), prompt, chdir: chdir)
    end

    def record_step_result(ctx)
      update_pipeline_state(ctx.role, ctx.result, ctx.state)
      ctx.state[:completed_steps] << ctx.idx
      ctx.state[:steps_run] += 1
      ctx.state[:total_cost] += ctx.result.cost_usd.to_f
      save_step_progress(ctx)
      post_step_completion_comment(ctx)

      check_step_failure(ctx) || check_cost_budget(ctx.state, ctx.logger)
    end

    def save_step_progress(ctx)
      pipeline_state.save(ctx.issue_number,
                          completed_steps: ctx.state[:completed_steps],
                          worktree_path: ctx.chdir,
                          branch: current_branch(ctx.chdir))
    end

    def check_step_failure(ctx)
      return nil if ctx.result.success? || !%w[implement merge].include?(ctx.role)

      ctx.logger.error("#{ctx.role} failed")
      { success: false, phase: ctx.role, output: ctx.result.output }
    end

    def check_cost_budget(state, logger)
      return nil unless @config.cost_budget && state[:total_cost] > @config.cost_budget

      cost = format('%.2f', state[:total_cost])
      budget = format('%.2f', @config.cost_budget)
      logger.error("Cost budget exceeded ($#{cost}/$#{budget})")
      { success: false, phase: 'budget', output: "Cost budget exceeded: $#{cost}" }
    end

    def skip_reason(step, state)
      condition = step[:condition]

      return 'manual review mode' if step[:role].to_s == 'merge' && @config.manual_review
      return 'audit mode' if step[:role].to_s == 'merge' && @config.audit_mode
      return 'fast-track issue (simple complexity)' if step[:complexity] == 'full' && state[:complexity] == 'simple'
      if condition == 'has_findings' && !state[:last_review_output]&.include?("\u{1F534}")
        return 'no blocking findings from review'
      end
      return 'no fixes were made' if condition == 'had_fixes' && !state[:had_fixes]

      nil
    end

    def update_pipeline_state(role, result, state)
      case role
      when 'review', 'verify', 'security', 'audit'
        state[:last_review_output] = result.output
      when 'fix'
        state[:had_fixes] = true
        state[:last_review_output] = nil
      when 'implement'
        state[:last_review_output] = nil
      end
    end

    def run_final_verification(issue_number, logger:, claude:, chdir:)
      return nil unless @config.test_command || @config.lint_check_command

      logger.info('--- Final verification ---')
      post_step_comment(issue_number, "\u{1F504} **Phase: final-verify** (verification)")
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = run_final_checks(logger, chdir: chdir)

      unless result[:success]
        logger.warn('Final checks failed, attempting fix...')
        post_step_comment(issue_number, "\u{26A0}\u{FE0F} **Final verification failed** \u2014 attempting auto-fix...")
        claude.run_agent('implementer',
                         "Fix these test/lint failures:\n\n#{result[:output]}",
                         chdir: chdir)
        result = run_final_checks(logger, chdir: chdir)
      end

      duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time).round
      if result[:success]
        post_step_comment(issue_number, "\u{2705} **Phase: final-verify** completed \u{2014} #{duration}s")
        nil
      else
        post_step_comment(issue_number, "\u{274C} **Phase: final-verify** failed \u{2014} #{duration}s")
        { success: false, phase: 'final-verify', output: result[:output] }
      end
    end

    def log_cost_summary(total_cost, logger)
      return if total_cost.zero?

      budget = @config.cost_budget
      budget_str = budget ? " / $#{format('%.2f', budget)} budget" : ''
      logger.info("Pipeline cost: $#{format('%.4f', total_cost)}#{budget_str}")
    end

    def pipeline_state
      @pipeline_state ||= PipelineState.new(log_dir: File.join(@config.project_dir, @config.log_dir))
    end

    def current_branch(chdir)
      stdout, = Open3.capture3('git', 'rev-parse', '--abbrev-ref', 'HEAD', chdir: chdir)
      stdout.strip
    rescue StandardError
      nil
    end

    def post_pipeline_start_comment(issue_number, state)
      total = @config.steps.size
      conditional = conditional_step_count(state)
      post_step_comment(issue_number,
                        "\u{1F680} **Pipeline started** \u2014 complexity: `#{state[:complexity]}` " \
                        "| steps: #{total} (#{conditional} may be skipped)")
    end

    def post_pipeline_summary_comment(issue_number, state, duration, success:, failed_phase: nil)
      total = @config.steps.size
      cost = format('%.2f', state[:total_cost])

      if success
        post_step_comment(issue_number,
                          "\u{2705} **Pipeline complete** \u2014 #{state[:steps_run]}/#{total} steps run " \
                          "| #{state[:steps_skipped]} skipped | $#{cost} total | #{duration}s")
      else
        post_step_comment(issue_number,
                          "\u{274C} **Pipeline failed** at phase: #{failed_phase} \u2014 " \
                          "#{state[:steps_run]}/#{total} steps completed | $#{cost} total")
      end
    end

    def conditional_step_count(state)
      @config.steps.count do |step|
        step = symbolize(step)
        step[:condition] ||
          (step[:complexity] == 'full' && state[:complexity] == 'simple') ||
          (step[:role].to_s == 'merge' && @config.manual_review)
      end
    end

    def post_step_comment(issue_number, body)
      @issues&.comment(issue_number, body)
    rescue StandardError
      nil # comment failures must never crash the pipeline
    end

    def post_step_completion_comment(ctx)
      duration = (ctx.result.duration_ms.to_f / 1000).round
      cost = format('%.3f', ctx.result.cost_usd.to_f)
      if ctx.result.success?
        post_step_comment(ctx.issue_number,
                          "\u{2705} **Phase: #{ctx.role}** completed \u{2014} #{duration}s | $#{cost}")
      else
        post_step_comment(ctx.issue_number,
                          "\u{274C} **Phase: #{ctx.role}** failed \u{2014} #{duration}s | $#{cost}")
      end
    end

    def symbolize(hash)
      return hash unless hash.is_a?(Hash)

      hash.transform_keys(&:to_sym)
    end
  end
end
