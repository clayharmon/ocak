# frozen_string_literal: true

require 'open3'

module Ocak
  class MergeManager
    def initialize(config:, claude:, logger:, watch: nil)
      @config = config
      @claude = claude
      @logger = logger
      @watch = watch
    end

    # Rebase, test, push, then let the merger agent create PR + merge + close issue.
    def merge(issue_number, worktree)
      @logger.info("Starting merge for issue ##{issue_number}")

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

    private

    def rebase_onto_main(worktree)
      git('fetch', 'origin', 'main', chdir: worktree.path)
      _, stderr, status = git('rebase', 'origin/main', chdir: worktree.path)

      unless status.success?
        @logger.warn("Rebase conflict, aborting: #{stderr}")
        git('rebase', '--abort', chdir: worktree.path)
        return false
      end

      true
    end

    def verify_tests(worktree)
      test_cmd = @config.test_command
      return true unless test_cmd

      @logger.info('Running tests after rebase...')
      _, _, status = shell(test_cmd, chdir: worktree.path)

      if status.success?
        @logger.info('Tests passed after rebase')
        true
      else
        @logger.warn('Tests failed after rebase')
        false
      end
    end

    def push_branch(worktree)
      _, stderr, status = git('push', '-u', 'origin', worktree.branch, chdir: worktree.path)

      unless status.success?
        @logger.error("Push failed: #{stderr}")
        return false
      end

      true
    end

    def git(*, chdir:)
      Open3.capture3('git', *, chdir: chdir)
    end

    def shell(cmd, chdir:)
      Open3.capture3(cmd, chdir: chdir)
    end
  end
end
