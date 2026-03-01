# frozen_string_literal: true

require 'open3'
require 'shellwords'
require_relative 'git_utils'

module Ocak
  class LocalMergeManager
    def initialize(config:, logger:, issues:, **_opts)
      @config = config
      @logger = logger
      @issues = issues
    end

    def merge(issue_number, worktree)
      @logger.info("Starting local merge for issue ##{issue_number}")

      commit_uncommitted_changes(issue_number, worktree)

      unless rebase_onto_main(worktree)
        @logger.error("Rebase failed for issue ##{issue_number}")
        return false
      end

      unless verify_tests(worktree)
        @logger.error("Tests failed after rebase for issue ##{issue_number}")
        return false
      end

      unless merge_to_main(worktree)
        @logger.error("Merge to main failed for issue ##{issue_number}")
        return false
      end

      delete_branch(worktree.branch)
      @logger.info("Issue ##{issue_number} merged to main (local)")
      true
    end

    def create_pr_only(issue_number, _worktree)
      @logger.warn("manual_review is not supported in fully local mode for issue ##{issue_number}")
      nil
    end

    private

    def commit_uncommitted_changes(issue_number, worktree)
      GitUtils.commit_changes(
        chdir: worktree.path,
        message: "chore: uncommitted pipeline changes for issue ##{issue_number}",
        logger: @logger
      )
    end

    def rebase_onto_main(worktree)
      _, stderr, status = git('rebase', 'main', chdir: worktree.path)
      return true if status.success?

      @logger.warn("Rebase failed: #{stderr[0..200]}")
      git('rebase', '--abort', chdir: worktree.path)
      false
    end

    def verify_tests(worktree)
      test_cmd = @config.test_command
      return true unless test_cmd

      @logger.info('Running tests after rebase...')
      _, _, status = Open3.capture3(*Shellwords.shellsplit(test_cmd), chdir: worktree.path)

      if status.success?
        @logger.info('Tests passed after rebase')
        true
      else
        @logger.warn('Tests failed after rebase')
        false
      end
    end

    def merge_to_main(worktree)
      _, stderr, status = git('checkout', 'main', chdir: @config.project_dir)
      unless status.success?
        @logger.error("Checkout main failed: #{stderr}")
        return false
      end

      _, stderr, status = git('merge', worktree.branch, '--ff-only', chdir: @config.project_dir)
      return true if status.success?

      @logger.warn("Fast-forward merge failed: #{stderr[0..200]}")
      false
    end

    def delete_branch(branch)
      git('branch', '-d', branch, chdir: @config.project_dir)
    rescue StandardError => e
      @logger.warn("Failed to delete branch #{branch}: #{e.message}")
    end

    def git(*, chdir:)
      Open3.capture3('git', *, chdir: chdir)
    end
  end
end
