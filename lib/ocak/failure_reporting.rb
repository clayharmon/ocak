# frozen_string_literal: true

module Ocak
  # Shared pipeline failure reporting — label transition + comment posting.
  # Included by PipelineRunner and Commands::Resume.
  module FailureReporting
    def report_pipeline_failure(issue_number, result, issues:, config:)
      issues.transition(issue_number, from: config.label_in_progress, to: config.label_failed)
      issues.comment(issue_number,
                     "Pipeline failed at phase: #{result[:phase]}\n\n```\n#{result[:output][0..1000]}\n```")
    end
  end
end
