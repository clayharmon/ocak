# frozen_string_literal: true

module Ocak
  # Rebase and conflict resolution logic — rebase_onto_main, resolve_conflicts_via_agent.
  # Extracted from MergeManager to reduce file size.
  module ConflictResolution
    private

    def rebase_onto_main(worktree)
      fetch_result = run_git('fetch', 'origin', 'main', chdir: worktree.path)
      unless fetch_result.success?
        @logger.error("git fetch origin main failed: #{fetch_result.error}")
        return false
      end

      rebase_result = run_git('rebase', 'origin/main', chdir: worktree.path)

      return true if rebase_result.success?

      @logger.warn("Rebase conflict, aborting rebase: #{rebase_result.error}")
      abort_result = run_git('rebase', '--abort', chdir: worktree.path)
      @logger.warn("git rebase --abort failed: #{abort_result.error}") unless abort_result.success?

      # Fall back to merge strategy
      @logger.info('Attempting merge strategy instead...')
      merge_result = run_git('merge', 'origin/main', '--no-edit', chdir: worktree.path)

      return true if merge_result.success?

      # Merge also has conflicts — try to resolve via agent
      @logger.warn("Merge conflict, attempting agent resolution: #{merge_result.error}")
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
  end
end
