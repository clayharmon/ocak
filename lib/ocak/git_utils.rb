# frozen_string_literal: true

require 'open3'
require_relative 'command_runner'

module Ocak
  module GitUtils
    class << self
      include CommandRunner
    end
    # Validates that a branch name is safe to pass to git commands.
    # Rejects names that could be interpreted as flags (starting with -)
    # or cause unexpected git behavior (containing ..).
    def self.safe_branch_name?(name)
      return false if name.nil? || name.empty?

      name.match?(%r{\A[a-zA-Z0-9_./-]+\z}) && !name.start_with?('-') && !name.include?('..')
    end

    # Stages and commits all changes in the given directory.
    # Returns true if changes were committed, false if no changes or on failure.
    # Logs warnings via logger on failure rather than raising.
    def self.commit_changes(chdir:, message:, logger: nil)
      result = run_git('status', '--porcelain', chdir: chdir)
      unless result.success?
        logger&.warn('git status --porcelain failed')
        return false
      end
      return false if result.output.empty?

      add_result = run_git('add', '-A', chdir: chdir)
      unless add_result.success?
        logger&.warn("git add failed: #{add_result.error}")
        return false
      end

      commit_result = run_git('commit', '-m', message, chdir: chdir)
      unless commit_result.success?
        logger&.warn("git commit failed: #{commit_result.error}")
        return false
      end

      true
    end

    # Checks out the main branch. Intended for cleanup/ensure blocks.
    # Rescues all errors so it never crashes the caller.
    def self.checkout_main(chdir:, logger: nil)
      result = run_git('checkout', 'main', chdir: chdir)
      unless result.success?
        # Use "error" prefix when command not found (status is nil), otherwise "failed"
        prefix = result.status.nil? ? 'Cleanup checkout to main error:' : 'Cleanup checkout to main failed:'
        logger&.warn("#{prefix} #{result.stderr}")
      end
    rescue StandardError => e
      logger&.warn("Cleanup checkout to main error: #{e.message}")
    end
  end
end
