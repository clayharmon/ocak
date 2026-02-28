# frozen_string_literal: true

require 'json'
require 'open3'

module Ocak
  # Merge/PR-creation orchestration logic extracted from PipelineRunner.
  module MergeOrchestration
    private

    def merge_completed_issue(result, merger:, issues:, logger:)
      if result[:audit_blocked]
        handle_batch_audit(result, merger: merger, issues: issues, logger: logger)
      elsif @config.manual_review
        handle_batch_manual_review(result, merger: merger, issues: issues, logger: logger)
      elsif merger.merge(result[:issue_number], result[:worktree])
        issues.transition(result[:issue_number], from: @config.label_in_progress, to: @config.label_completed)
        logger.info("Issue ##{result[:issue_number]} merged successfully")
      else
        issues.transition(result[:issue_number], from: @config.label_in_progress, to: @config.label_failed)
        logger.error("Issue ##{result[:issue_number]} merge failed")
      end
    end

    def handle_single_success(issue_number, result, logger:, claude:, issues:)
      if result[:audit_blocked]
        handle_single_audit_blocked(issue_number, result, logger: logger, claude: claude, issues: issues)
      elsif @config.manual_review
        handle_single_manual_review(issue_number, logger: logger, claude: claude, issues: issues)
      else
        claude.run_agent('merger', "Create a PR, merge it, and close issue ##{issue_number}",
                         chdir: @config.project_dir)
        issues.transition(issue_number, from: @config.label_in_progress, to: @config.label_completed)
        logger.info("Issue ##{issue_number} completed successfully")
      end
    end

    def handle_single_manual_review(issue_number, logger:, claude:, issues:)
      claude.run_agent('merger',
                       "Create a PR for issue ##{issue_number} but do NOT merge it and do NOT close the issue",
                       chdir: @config.project_dir)
      issues.transition(issue_number, from: @config.label_in_progress, to: @config.label_awaiting_review)
      logger.info("Issue ##{issue_number} PR created (manual review mode)")
    end

    def handle_batch_manual_review(result, merger:, issues:, logger:)
      pr_number = merger.create_pr_only(result[:issue_number], result[:worktree])
      if pr_number
        issues.transition(result[:issue_number], from: @config.label_in_progress,
                                                 to: @config.label_awaiting_review)
        logger.info("Issue ##{result[:issue_number]} PR ##{pr_number} created (manual review mode)")
      else
        issues.transition(result[:issue_number], from: @config.label_in_progress, to: @config.label_failed)
        logger.error("Issue ##{result[:issue_number]} PR creation failed")
      end
    end

    def handle_single_audit_blocked(issue_number, result, logger:, claude:, issues:)
      handle_single_manual_review(issue_number, logger: logger, claude: claude, issues: issues)
      post_audit_comment_single(result[:audit_output], logger: logger, issues: issues)
    end

    def handle_batch_audit(result, merger:, issues:, logger:)
      create_pr_with_audit(result, result[:audit_output], merger: merger, issues: issues, logger: logger)
    end

    def create_pr_with_audit(result, audit_output, merger:, issues:, logger:)
      pr_number = merger.create_pr_only(result[:issue_number], result[:worktree])
      if pr_number
        issues.pr_comment(pr_number, "## Audit Report\n\n#{audit_output}")
        issues.transition(result[:issue_number], from: @config.label_in_progress,
                                                 to: @config.label_awaiting_review)
        logger.info("Issue ##{result[:issue_number]} PR ##{pr_number} created (audit findings)")
      else
        issues.transition(result[:issue_number], from: @config.label_in_progress, to: @config.label_failed)
        logger.error("Issue ##{result[:issue_number]} PR creation failed")
      end
    end

    def post_audit_comment_single(audit_output, logger:, issues:)
      pr_number = find_pr_for_branch(logger: logger)
      unless pr_number
        logger.warn("Could not find PR to post audit comment — findings were: #{audit_output.to_s[0..200]}")
        return
      end

      issues.pr_comment(pr_number, "## Audit Report\n\n#{audit_output}")
      logger.info("Posted audit comment on PR ##{pr_number}")
    end

    def find_pr_for_branch(logger:)
      stdout, _, status = Open3.capture3('gh', 'pr', 'view', '--json', 'number', chdir: @config.project_dir)
      return nil unless status.success?

      data = JSON.parse(stdout)
      data['number']
    rescue JSON::ParserError => e
      logger.warn("Failed to find PR number: #{e.message}")
      nil
    end
  end
end
