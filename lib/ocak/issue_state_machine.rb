# frozen_string_literal: true

module Ocak
  # Encapsulates all valid label transitions for pipeline issue processing.
  # Replaces scattered issues.transition calls with named, intention-revealing methods.
  class IssueStateMachine
    def initialize(config:, issues:)
      @config = config
      @issues = issues
    end

    def mark_in_progress(issue_number)
      @issues&.transition(issue_number, from: @config.label_ready, to: @config.label_in_progress)
    end

    def mark_completed(issue_number)
      @issues&.transition(issue_number, from: @config.label_in_progress, to: @config.label_completed)
    end

    def mark_failed(issue_number)
      @issues&.transition(issue_number, from: @config.label_in_progress, to: @config.label_failed)
    end

    def mark_interrupted(issue_number)
      @issues&.transition(issue_number, from: @config.label_in_progress, to: @config.label_ready)
    end

    def mark_for_review(issue_number)
      @issues&.transition(issue_number, from: @config.label_in_progress, to: @config.label_awaiting_review)
    end

    def mark_resuming(issue_number)
      @issues&.transition(issue_number, from: @config.label_failed, to: @config.label_in_progress)
    end
  end
end
