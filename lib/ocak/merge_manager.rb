# frozen_string_literal: true

require 'open3'
require 'shellwords'
require_relative 'git_utils'
require_relative 'command_runner'

module Ocak
  class MergeManager
    include CommandRunner

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
        "Create a PR, merge it, and close issue ##{issue_number}. Branch: #{worktree.branch}",
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

    def log_and_nil(message)
      @logger.error(message)
      nil
    end

    def open_pull_request(issue_number, worktree)
      issue_title = fetch_issue_title(issue_number)
      pr_title = "Fix ##{issue_number}: #{issue_title}"
      pr_body = "Closes ##{issue_number}\n\n" \
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

    def rebase_onto_main(worktree)
      fetch_result = run_git('fetch', 'origin', 'main', chdir: worktree.path)
      unless fetch_result.success?
        @logger.error("git fetch origin main failed: #{fetch_result.error}")
        return false
      end

      rebase_result = run_git('rebase', 'origin/main', chdir: worktree.path)

      return true if rebase_result.success?

      @logger.warn("Rebase conflict, aborting rebase: #{rebase_result.stderr}")
      abort_result = run_git('rebase', '--abort', chdir: worktree.path)
      @logger.warn("git rebase --abort failed: #{abort_result.error}") unless abort_result.success?

      # Fall back to merge strategy
      @logger.info('Attempting merge strategy instead...')
      merge_result = run_git('merge', 'origin/main', '--no-edit', chdir: worktree.path)

      return true if merge_result.success?

      # Merge also has conflicts — try to resolve via agent
      @logger.warn("Merge conflict, attempting agent resolution: #{merge_result.stderr}")
      resolve_conflicts_via_agent(worktree)
    end

    def resolve_conflicts_via_agent(worktree)
      # Get list of conflicting files
      diff_result = run_git('diff', '--name-only', '--diff-filter=U', chdir: worktree.path)
      conflicting = diff_result.stdout.lines.map(&:strip).reject(&:empty?)

      if conflicting.empty?
        @logger.warn('No conflicting files found, aborting merge')
        run_git('merge', '--abort', chdir: worktree.path)
        return false
      end

      result = @claude.run_agent(
        'implementer',
        "Resolve these merge conflicts.\n\n<conflicting_files>\n#{conflicting.join("\n")}\n</conflicting_files>\n\n" \
        'Open each file, find conflict markers (<<<<<<< ======= >>>>>>>), and resolve them. ' \
        'Then run `git add` on each resolved file.',
        chdir: worktree.path
      )

      if result.success?
        # Check if all conflicts resolved
        remaining_result = run_git('diff', '--name-only', '--diff-filter=U', chdir: worktree.path)
        if remaining_result.output.empty?
          commit_result = run_git('commit', '--no-edit', chdir: worktree.path)
          unless commit_result.success?
            @logger.error("Commit after conflict resolution failed: #{commit_result.error}")
            return false
          end
          @logger.info('Merge conflicts resolved by agent')
          return true
        end
      end

      @logger.error('Agent could not resolve merge conflicts')
      run_git('merge', '--abort', chdir: worktree.path)
      false
    end

    def verify_tests(worktree)
      test_cmd = @config.test_command
      return true unless test_cmd

      @logger.info('Running tests after rebase...')
      stdout, stderr, status = shell(test_cmd, chdir: worktree.path)

      if status.success?
        @logger.info('Tests passed after rebase')
        true
      else
        @logger.warn('Tests failed after rebase')
        @logger.debug("Test output:\n#{stdout[0..2000]}\n#{stderr[0..500]}")
        false
      end
    end

    def push_branch(worktree)
      result = run_git('push', '-u', 'origin', worktree.branch, chdir: worktree.path)

      unless result.success?
        @logger.error("Push failed: #{result.error}")
        return false
      end

      true
    end

    def shell(cmd, chdir:)
      Open3.capture3(*Shellwords.shellsplit(cmd), chdir: chdir)
    end
  end
end
