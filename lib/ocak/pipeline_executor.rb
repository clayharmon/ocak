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

    def initialize(config:)
      @config = config
    end

    def run_pipeline(issue_number, logger:, claude:, chdir: nil, skip_steps: [], complexity: 'full')
      chdir ||= @config.project_dir
      logger.info("=== Starting pipeline for issue ##{issue_number} (#{complexity}) ===")

      state = { last_review_output: nil, had_fixes: false, completed_steps: [], total_cost: 0.0,
                complexity: complexity }

      failure = run_pipeline_steps(issue_number, state, logger: logger, claude: claude, chdir: chdir,
                                                        skip_steps: skip_steps)
      log_cost_summary(state[:total_cost], logger)
      return failure if failure

      failure = run_final_verification(logger: logger, claude: claude, chdir: chdir)
      return failure if failure

      pipeline_state.delete(issue_number)

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

        next if skip_step?(step, state, logger)

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
      prompt = build_step_prompt(role, issue_number, review_output)
      claude.run_agent(agent.tr('_', '-'), prompt, chdir: chdir)
    end

    def record_step_result(ctx)
      update_pipeline_state(ctx.role, ctx.result, ctx.state)
      ctx.state[:completed_steps] << ctx.idx
      ctx.state[:total_cost] += ctx.result.cost_usd.to_f
      save_step_progress(ctx)

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

    def skip_step?(step, state, logger)
      role = step[:role].to_s
      condition = step[:condition]

      if step[:complexity] == 'full' && state[:complexity] == 'simple'
        logger.info("Skipping #{role} — fast-track issue")
        return true
      end
      if condition == 'has_findings' && !state[:last_review_output]&.include?("\u{1F534}")
        logger.info("Skipping #{role} — no blocking findings")
        return true
      end
      if condition == 'had_fixes' && !state[:had_fixes]
        logger.info("Skipping #{role} — no fixes were made")
        return true
      end
      false
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

    def run_final_verification(logger:, claude:, chdir:)
      return nil unless @config.test_command || @config.lint_check_command

      logger.info('--- Final verification ---')
      result = run_final_checks(logger, chdir: chdir)
      return nil if result[:success]

      logger.warn('Final checks failed, attempting fix...')
      claude.run_agent('implementer',
                       "Fix these test/lint failures:\n\n#{result[:output]}",
                       chdir: chdir)
      result = run_final_checks(logger, chdir: chdir)
      return nil if result[:success]

      { success: false, phase: 'final-verify', output: result[:output] }
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

    def symbolize(hash)
      return hash unless hash.is_a?(Hash)

      hash.transform_keys(&:to_sym)
    end
  end
end
