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
        @state_machine.mark_completed(result[:issue_number])
        logger.info("Issue ##{result[:issue_number]} merged successfully")
      else
        @state_machine.mark_failed(result[:issue_number])
        logger.error("Issue ##{result[:issue_number]} merge failed")
      end
    end

    def handle_single_success(issue_number, result, logger:, claude:, issues:)
      target_dir = result[:target_repo]&.dig(:path) || @config.project_dir

      if result[:audit_blocked]
        handle_single_audit_blocked(issue_number, result, logger: logger, claude: claude, issues: issues,
                                                          chdir: target_dir)
      elsif @config.manual_review
        handle_single_manual_review(issue_number, logger: logger, claude: claude, issues: issues, chdir: target_dir)
      else
        unless pipeline_has_merge_step?
          prompt = if result[:target_repo]
                     "Create a PR and merge it for issue ##{issue_number}. " \
                       'Do NOT close any issues (the issue lives in a different repository).'
                   else
                     "Create a PR, merge it, and close issue ##{issue_number}"
                   end
          claude.run_agent('merger', prompt, chdir: target_dir)
        end
        @state_machine.mark_completed(issue_number)
        logger.info("Issue ##{issue_number} completed successfully")
      end
    end

    def handle_single_manual_review(issue_number, logger:, claude:, issues: nil, chdir: @config.project_dir) # rubocop:disable Lint/UnusedMethodArgument
      claude.run_agent('merger',
                       "Create a PR for issue ##{issue_number} but do NOT merge it and do NOT close the issue",
                       chdir: chdir)
      @state_machine.mark_for_review(issue_number)
      logger.info("Issue ##{issue_number} PR created (manual review mode)")
    end

    def handle_batch_manual_review(result, merger:, logger:, issues: nil) # rubocop:disable Lint/UnusedMethodArgument
      pr_number = merger.create_pr_only(result[:issue_number], result[:worktree])
      if pr_number
        @state_machine.mark_for_review(result[:issue_number])
        logger.info("Issue ##{result[:issue_number]} PR ##{pr_number} created (manual review mode)")
      else
        @state_machine.mark_failed(result[:issue_number])
        logger.error("Issue ##{result[:issue_number]} PR creation failed")
      end
    end

    def handle_single_audit_blocked(issue_number, result, logger:, claude:, issues:, chdir: @config.project_dir)
      handle_single_manual_review(issue_number, logger: logger, claude: claude, issues: issues, chdir: chdir)
      post_audit_comment_single(result[:audit_output], logger: logger, issues: issues, chdir: chdir)
    end

    def handle_batch_audit(result, merger:, issues:, logger:)
      create_pr_with_audit(result, result[:audit_output], merger: merger, issues: issues, logger: logger)
    end

    def create_pr_with_audit(result, audit_output, merger:, issues:, logger:)
      pr_number = merger.create_pr_only(result[:issue_number], result[:worktree])
      if pr_number
        issues.pr_comment(pr_number, "## Audit Report\n\n#{audit_output}")
        @state_machine.mark_for_review(result[:issue_number])
        logger.info("Issue ##{result[:issue_number]} PR ##{pr_number} created (audit findings)")
      else
        @state_machine.mark_failed(result[:issue_number])
        logger.error("Issue ##{result[:issue_number]} PR creation failed")
      end
    end

    def post_audit_comment_single(audit_output, logger:, issues:, chdir: @config.project_dir)
      pr_number = find_pr_for_branch(logger: logger, chdir: chdir)
      unless pr_number
        logger.warn("Could not find PR to post audit comment — findings were: #{audit_output.to_s[0..200]}")
        return
      end

      issues.pr_comment(pr_number, "## Audit Report\n\n#{audit_output}")
      logger.info("Posted audit comment on PR ##{pr_number}")
    end

    def pipeline_has_merge_step?
      @config.steps.any? { |s| s[:role].to_s == 'merge' || s['role'].to_s == 'merge' }
    end

    def find_pr_for_branch(logger:, chdir: @config.project_dir)
      stdout, _, status = Open3.capture3('gh', 'pr', 'view', '--json', 'number', chdir: chdir)
      return nil unless status.success?

      data = JSON.parse(stdout)
      data['number']
    rescue JSON::ParserError => e
      logger.warn("Failed to find PR number: #{e.message}")
      nil
    end
  end
end
