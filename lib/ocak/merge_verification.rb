# frozen_string_literal: true

require 'open3'
require 'shellwords'

module Ocak
  # Test verification and git push logic — verify_tests, push_branch.
  # Extracted from MergeManager to reduce file size.
  module MergeVerification
    private

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
  end
end
