# frozen_string_literal: true

module Ocak
  # Shared pipeline failure reporting — label transition + comment posting.
  # Included by PipelineRunner and Commands::Resume.
  module FailureReporting
    def report_pipeline_failure(issue_number, result, issues:, config:)
      issues.transition(issue_number, from: config.label_in_progress, to: config.label_failed)
      sanitized = result[:output][0..1000].to_s.gsub('```', "'''")
      issues.comment(issue_number,
                     "Pipeline failed at phase: #{result[:phase]}\n\n```\n#{sanitized}\n```")
    rescue StandardError
      nil
    end
  end
end
