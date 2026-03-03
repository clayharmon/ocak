# frozen_string_literal: true

module Ocak
  # Individual step execution logic extracted from PipelineExecutor.
  # Includers must provide @config, @skip_steps, post_step_comment, build_step_prompt methods.
  module StepExecution
    def run_single_step(step, idx, issue_number, state, logger:, claude:, chdir:, mutex: nil) # rubocop:disable Metrics/ParameterLists
      role = step[:role].to_s
      agent = step[:agent].to_s

      return nil if handle_already_completed(idx, role, @skip_steps, logger)

      reason = skip_reason(step, state)
      if reason
        logger.info("Skipping #{role} — #{reason}")
        record_skipped_step(issue_number, state, idx, agent, role, reason)
        return nil
      end

      result = execute_step(step, issue_number, state[:last_review_output], logger: logger, claude: claude,
                                                                            chdir: chdir)
      state[:report].record_step(index: idx, agent: agent, role: role, status: 'completed', result: result)
      ctx = StateManagement::StepContext.new(issue_number, idx, role, result, state, logger, chdir)
      record_step_result(ctx, mutex: mutex)
    end

    def handle_already_completed(idx, role, skip_steps, logger)
      return false unless skip_steps.include?(idx)

      logger.info("Skipping #{role} (already completed)")
      true
    end

    def record_skipped_step(issue_number, state, idx, agent, role, reason)
      post_step_comment(issue_number, "⏭️ **Skipping #{role}** — #{reason}")
      state[:report].record_step(index: idx, agent: agent, role: role, status: 'skipped', skip_reason: reason)
      state[:steps_skipped] += 1
    end

    def execute_step(step, issue_number, review_output, logger:, claude:, chdir:)
      agent = step[:agent].to_s
      role = step[:role].to_s
      logger.info("--- Phase: #{role} (#{agent}) ---")
      post_step_comment(issue_number, "🔄 **Phase: #{role}** (#{agent})")
      prompt = build_step_prompt(role, issue_number, review_output)
      opts = { chdir: chdir }
      opts[:model] = step[:model].to_s if step[:model]
      claude.run_agent(agent.tr('_', '-'), prompt, **opts)
    end

    def skip_reason(step, state)
      condition = step[:condition]

      return 'audit found blocking issues' if step[:role].to_s == 'merge' && @config.audit_mode && state[:audit_blocked]
      return 'manual review mode' if step[:role].to_s == 'merge' && @config.manual_review
      return 'fast-track issue (simple complexity)' if step[:complexity] == 'full' && state[:complexity] == 'simple'
      if condition == 'has_findings' && !state[:last_review_output]&.include?('🔴')
        return 'no blocking findings from review'
      end
      return 'no fixes were made' if condition == 'had_fixes' && !state[:had_fixes]

      nil
    end
  end
end
