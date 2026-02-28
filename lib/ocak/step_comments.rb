# frozen_string_literal: true

module Ocak
  # Shared comment-posting helpers for pipeline steps.
  # Includers must provide an @issues instance variable (IssueFetcher or nil).
  module StepComments
    def post_step_comment(issue_number, body)
      @issues&.comment(issue_number, body)
    rescue StandardError
      nil
    end

    def post_step_completion_comment(issue_number, role, result)
      duration = (result.duration_ms.to_f / 1000).round
      cost = format('%.3f', result.cost_usd.to_f)
      if result.success?
        post_step_comment(issue_number, "\u{2705} **Phase: #{role}** completed \u2014 #{duration}s | $#{cost}")
      else
        post_step_comment(issue_number, "\u{274C} **Phase: #{role}** failed \u2014 #{duration}s | $#{cost}")
      end
    end
  end
end
