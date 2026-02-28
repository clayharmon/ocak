# frozen_string_literal: true

module Ocak
  # Shared comment-posting methods for pipeline progress comments.
  # Includers must provide @issues (IssueFetcher or nil) and @config (Config).
  module StepComments
    private

    def post_step_comment(issue_number, body)
      @issues&.comment(issue_number, body)
    rescue StandardError
      nil # comment failures must never crash the pipeline
    end

    def post_step_completion_comment(issue_number, role, result)
      duration = (result.duration_ms.to_f / 1000).round
      cost = format('%.3f', result.cost_usd.to_f)
      if result.success?
        post_step_comment(issue_number, "\u{2705} **Phase: #{role}** completed \u{2014} #{duration}s | $#{cost}")
      else
        post_step_comment(issue_number, "\u{274C} **Phase: #{role}** failed \u{2014} #{duration}s | $#{cost}")
      end
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
          (step[:role].to_s == 'merge' && @config.manual_review) ||
          (step[:role].to_s == 'merge' && @config.audit_mode) # merge may be skipped if audit finds blocking issues
      end
    end
  end
end
