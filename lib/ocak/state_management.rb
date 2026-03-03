# frozen_string_literal: true

require 'fileutils'

module Ocak
  # State accumulation and reporting logic extracted from PipelineExecutor.
  # Includers must provide @config, @logger instance variables and pipeline_state, current_branch methods.
  module StateManagement
    StepContext = Struct.new(:issue_number, :idx, :role, :result, :state, :logger, :chdir)

    def record_step_result(ctx, mutex: nil)
      sync(mutex) { accumulate_state(ctx) }
      save_step_progress(ctx)
      write_step_output(ctx.issue_number, ctx.idx, ctx.role, ctx.result.output)
      post_step_completion_comment(ctx.issue_number, ctx.role, ctx.result)

      check_step_failure(ctx) || check_cost_budget(ctx.state, ctx.logger)
    end

    def accumulate_state(ctx)
      update_pipeline_state(ctx.role, ctx.result, ctx.state)
      ctx.state[:completed_steps] << ctx.idx
      ctx.state[:steps_run] += 1
      ctx.state[:total_cost] += ctx.result.cost_usd.to_f
      ctx.state[:step_results][ctx.role] = ctx.result
    end

    def sync(mutex, &)
      if mutex
        mutex.synchronize(&)
      else
        yield
      end
    end

    def save_step_progress(ctx)
      pipeline_state.save(ctx.issue_number,
                          completed_steps: ctx.state[:completed_steps],
                          worktree_path: ctx.chdir,
                          branch: current_branch(ctx.chdir, logger: ctx.logger))
    end

    def write_step_output(issue_number, idx, agent, output)
      return if output.to_s.empty?
      return unless issue_number.to_s.match?(/\A\d+\z/)

      safe_agent = agent.to_s.gsub(/[^a-zA-Z0-9_-]/, '')
      dir = File.join(@config.project_dir, '.ocak', 'logs', "issue-#{issue_number}")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "step-#{idx}-#{safe_agent}.md"), output)
    rescue StandardError => e
      @logger&.debug("Step output write failed: #{e.message}")
      nil
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

    def update_pipeline_state(role, result, state)
      case role
      when 'review', 'verify', 'security', 'audit'
        state[:last_review_output] = result.output
        if role == 'audit'
          state[:audit_output] = result.output
          state[:audit_blocked] = !result.success? || result.output.to_s.match?(/BLOCK|🔴/)
        end
      when 'fix'
        state[:had_fixes] = true
        state[:last_review_output] = nil
      when 'implement'
        state[:last_review_output] = nil
      end
    end

    def log_cost_summary(total_cost, logger)
      return if total_cost.zero?

      budget = @config.cost_budget
      budget_str = budget ? " / $#{format('%.2f', budget)} budget" : ''
      logger.info("Pipeline cost: $#{format('%.4f', total_cost)}#{budget_str}")
    end

    def save_report(report, issue_number, success:, failed_phase: nil)
      report.finish(success: success, failed_phase: failed_phase)
      report.save(issue_number, project_dir: @config.project_dir)
    rescue StandardError => e
      @logger&.debug("Report save failed: #{e.message}")
      nil
    end
  end
end
