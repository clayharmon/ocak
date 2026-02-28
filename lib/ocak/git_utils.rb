# frozen_string_literal: true

require 'open3'

module Ocak
  module GitUtils
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
      stdout, _, status = Open3.capture3('git', 'status', '--porcelain', chdir: chdir)
      unless status.success?
        logger&.warn('git status --porcelain failed')
        return false
      end
      return false if stdout.strip.empty?

      _, stderr, add_status = Open3.capture3('git', 'add', '-A', chdir: chdir)
      unless add_status.success?
        logger&.warn("git add failed: #{stderr[0..200]}")
        return false
      end

      _, stderr, commit_status = Open3.capture3('git', 'commit', '-m', message, chdir: chdir)
      unless commit_status.success?
        logger&.warn("git commit failed: #{stderr[0..200]}")
        return false
      end

      true
    end
  end
end
