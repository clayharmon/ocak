# frozen_string_literal: true

require 'open3'
require 'shellwords'
require_relative 'git_utils'
require_relative 'command_runner'
require_relative 'conflict_resolution'
require_relative 'merge_verification'

module Ocak
  class MergeManager
    include CommandRunner
    include ConflictResolution
    include MergeVerification

    def initialize(config:, claude:, logger:, issues:, watch: nil)
      @config = config
      @claude = claude
      @logger = logger
      @issues = issues
      @watch = watch
    end

    # Rebase, test, push, then let the merger agent create PR + merge + close issue.
    def merge(issue_number, worktree)
      @logger.info("Starting merge for issue ##{issue_number}")

      commit_uncommitted_changes(issue_number, worktree)

      unless rebase_onto_main(worktree)
        @logger.error("Rebase failed for issue ##{issue_number}")
        return false
      end

      unless verify_tests(worktree)
        @logger.error("Tests failed after rebase for issue ##{issue_number}")
        return false
      end

      unless push_branch(worktree)
        @logger.error("Push failed for issue ##{issue_number}")
        return false
      end

      result = @claude.run_agent(
        'merger',
        merger_prompt(issue_number, worktree),
        chdir: worktree.path
      )

      if result.success?
        @logger.info("Issue ##{issue_number} merged successfully")
        true
      else
        @logger.error("Merger agent failed for issue ##{issue_number}")
        false
      end
    end

    # Create a PR without merging (manual review mode).
    # Returns the PR number on success, nil on failure.
    def create_pr_only(issue_number, worktree)
      @logger.info("Creating PR (manual review) for issue ##{issue_number}")

      commit_uncommitted_changes(issue_number, worktree)
      return log_and_nil("Rebase failed for issue ##{issue_number}") unless rebase_onto_main(worktree)
      return log_and_nil("Tests failed after rebase for issue ##{issue_number}") unless verify_tests(worktree)
      return log_and_nil("Push failed for issue ##{issue_number}") unless push_branch(worktree)

      open_pull_request(issue_number, worktree)
    end

    private

    def merger_prompt(issue_number, worktree)
      if worktree.target_repo
        "Create a PR and merge it for issue ##{issue_number}. Branch: #{worktree.branch}. " \
          'Do NOT close any issues (the issue lives in a different repository).'
      else
        "Create a PR, merge it, and close issue ##{issue_number}. Branch: #{worktree.branch}"
      end
    end

    def log_and_nil(message)
      @logger.error(message)
      nil
    end

    def open_pull_request(issue_number, worktree)
      issue_title = fetch_issue_title(issue_number)
      pr_title = "Fix ##{issue_number}: #{issue_title}"
      issue_ref = if worktree.target_repo
                    god_nwo = @issues.repo_nwo
                    ref = god_nwo ? "#{god_nwo}##{issue_number}" : "##{issue_number}"
                    "Related to #{ref}"
                  else
                    "Closes ##{issue_number}"
                  end
      pr_body = "#{issue_ref}\n\n" \
                '_This PR was created in manual review mode. ' \
                'Review and label `auto-reready` to trigger automated fixes based on your feedback._'

      result = run_gh(
        'pr', 'create',
        '--title', pr_title,
        '--body', pr_body,
        '--head', worktree.branch,
        chdir: worktree.path
      )

      unless result.success?
        @logger.error("PR creation failed: #{result.error}")
        return nil
      end

      extract_pr_number(result.stdout)
    end

    def fetch_issue_title(issue_number)
      data = @issues.view(issue_number, fields: 'title')
      data&.dig('title') || "Issue #{issue_number}"
    end

    def extract_pr_number(gh_output)
      match = gh_output.match(%r{/pull/(\d+)})
      match ? match[1].to_i : nil
    end

    def commit_uncommitted_changes(issue_number, worktree)
      GitUtils.commit_changes(
        chdir: worktree.path,
        message: "chore: uncommitted pipeline changes for issue ##{issue_number}",
        logger: @logger
      )
    end

    def shell(cmd, chdir:)
      Open3.capture3(*Shellwords.shellsplit(cmd), chdir: chdir)
    end
  end
end
