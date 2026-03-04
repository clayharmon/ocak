# frozen_string_literal: true

require_relative 'issue_state_machine'

module Ocak
  # Shared pipeline failure reporting — label transition + comment posting.
  # Included by PipelineRunner and Commands::Resume.
  module FailureReporting
    def report_pipeline_failure(issue_number, result, issues:, config:, logger: nil)
      IssueStateMachine.new(config: config, issues: issues).mark_failed(issue_number)
      sanitized = result[:output][0..1000].to_s.gsub('```', "'''")
      issues.comment(issue_number,
                     "Pipeline failed at phase: #{result[:phase]}\n\n```\n#{sanitized}\n```")
    rescue StandardError => e
      logger&.debug("Failure report failed: #{e.message}")
      nil
    end
  end
end
