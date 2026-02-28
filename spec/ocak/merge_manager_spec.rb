# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Ocak::MergeManager do
  let(:config) do
    instance_double(Ocak::Config,
                    project_dir: '/project',
                    test_command: 'bundle exec rspec')
  end

  let(:logger) do
    instance_double(Ocak::PipelineLogger, info: nil, warn: nil, error: nil)
  end

  let(:claude) do
    instance_double(Ocak::ClaudeRunner)
  end

  let(:issues) do
    instance_double(Ocak::IssueFetcher)
  end

  let(:worktree) do
    Ocak::WorktreeManager::Worktree.new(
      path: '/project/.claude/worktrees/issue-42',
      branch: 'auto/issue-42-abc123',
      issue_number: 42
    )
  end

  subject(:manager) { described_class.new(config: config, claude: claude, logger: logger, issues: issues) }

  describe '#merge' do
    let(:success_status) { instance_double(Process::Status, success?: true) }
    let(:failure_status) { instance_double(Process::Status, success?: false) }

    # All contexts need the commit_uncommitted_changes stub (clean worktree by default)
    before do
      allow(Open3).to receive(:capture3)
        .with('git', 'status', '--porcelain', chdir: worktree.path)
        .and_return(['', '', success_status])
    end

    context 'when everything succeeds' do
      before do
        # Rebase
        allow(Open3).to receive(:capture3)
          .with('git', 'fetch', 'origin', 'main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', 'origin/main', chdir: worktree.path)
          .and_return(['', '', success_status])

        # Tests
        allow(Open3).to receive(:capture3)
          .with('bundle', 'exec', 'rspec', chdir: worktree.path)
          .and_return(['', '', success_status])

        # Push
        allow(Open3).to receive(:capture3)
          .with('git', 'push', '-u', 'origin', worktree.branch, chdir: worktree.path)
          .and_return(['', '', success_status])

        # Merger agent
        allow(claude).to receive(:run_agent)
          .and_return(Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'PR created and merged'))
      end

      it 'returns true' do
        expect(manager.merge(42, worktree)).to be true
      end

      it 'calls the merger agent' do
        expect(claude).to receive(:run_agent)
          .with('merger', anything, chdir: worktree.path)

        manager.merge(42, worktree)
      end
    end

    context 'when rebase fails and merge also fails' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'fetch', 'origin', 'main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', 'origin/main', chdir: worktree.path)
          .and_return(['', 'conflict', failure_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', '--abort', chdir: worktree.path)
          .and_return(['', '', success_status])
        # Merge fallback also fails
        allow(Open3).to receive(:capture3)
          .with('git', 'merge', 'origin/main', '--no-edit', chdir: worktree.path)
          .and_return(['', 'conflict', failure_status])
        # Conflict file list
        allow(Open3).to receive(:capture3)
          .with('git', 'diff', '--name-only', '--diff-filter=U', chdir: worktree.path)
          .and_return(["file.rb\n", '', success_status])
        # Agent fails to resolve
        allow(claude).to receive(:run_agent)
          .and_return(Ocak::ClaudeRunner::AgentResult.new(success: false, output: 'Could not resolve'))
        allow(Open3).to receive(:capture3)
          .with('git', 'merge', '--abort', chdir: worktree.path)
          .and_return(['', '', success_status])
      end

      it 'returns false' do
        expect(manager.merge(42, worktree)).to be false
      end

      it 'aborts the rebase before trying merge' do
        expect(Open3).to receive(:capture3)
          .with('git', 'rebase', '--abort', chdir: worktree.path)

        manager.merge(42, worktree)
      end

      it 'attempts merge as fallback' do
        expect(Open3).to receive(:capture3)
          .with('git', 'merge', 'origin/main', '--no-edit', chdir: worktree.path)

        manager.merge(42, worktree)
      end
    end

    context 'when rebase fails but merge succeeds' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'fetch', 'origin', 'main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', 'origin/main', chdir: worktree.path)
          .and_return(['', 'conflict', failure_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', '--abort', chdir: worktree.path)
          .and_return(['', '', success_status])
        # Merge fallback succeeds
        allow(Open3).to receive(:capture3)
          .with('git', 'merge', 'origin/main', '--no-edit', chdir: worktree.path)
          .and_return(['', '', success_status])
        # Tests pass
        allow(Open3).to receive(:capture3)
          .with('bundle', 'exec', 'rspec', chdir: worktree.path)
          .and_return(['', '', success_status])
        # Push succeeds
        allow(Open3).to receive(:capture3)
          .with('git', 'push', '-u', 'origin', worktree.branch, chdir: worktree.path)
          .and_return(['', '', success_status])
        # Merger agent succeeds
        allow(claude).to receive(:run_agent)
          .and_return(Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Merged'))
      end

      it 'returns true' do
        expect(manager.merge(42, worktree)).to be true
      end
    end

    context 'when git rebase --abort fails' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'fetch', 'origin', 'main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', 'origin/main', chdir: worktree.path)
          .and_return(['', 'conflict', failure_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', '--abort', chdir: worktree.path)
          .and_return(['', 'error: could not abort', failure_status])
        # Merge fallback succeeds
        allow(Open3).to receive(:capture3)
          .with('git', 'merge', 'origin/main', '--no-edit', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('bundle', 'exec', 'rspec', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'push', '-u', 'origin', worktree.branch, chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(claude).to receive(:run_agent)
          .and_return(Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Merged'))
      end

      it 'logs a warning about the abort failure' do
        manager.merge(42, worktree)

        expect(logger).to have_received(:warn).with(/git rebase --abort failed/)
      end
    end

    context 'when agent resolves conflicts but commit fails' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'fetch', 'origin', 'main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', 'origin/main', chdir: worktree.path)
          .and_return(['', 'conflict', failure_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', '--abort', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'merge', 'origin/main', '--no-edit', chdir: worktree.path)
          .and_return(['', 'conflict', failure_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'diff', '--name-only', '--diff-filter=U', chdir: worktree.path)
          .and_return(["file.rb\n", '', success_status], ['', '', success_status])
        allow(claude).to receive(:run_agent)
          .and_return(Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Resolved'))
        allow(Open3).to receive(:capture3)
          .with('git', 'commit', '--no-edit', chdir: worktree.path)
          .and_return(['', 'nothing to commit', failure_status])
      end

      it 'returns false' do
        expect(manager.merge(42, worktree)).to be false
      end

      it 'logs an error with stderr' do
        manager.merge(42, worktree)

        expect(logger).to have_received(:error).with(/Commit after conflict resolution failed: nothing to commit/)
      end
    end

    context 'when agent resolves conflicts and commit succeeds' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'fetch', 'origin', 'main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', 'origin/main', chdir: worktree.path)
          .and_return(['', 'conflict', failure_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', '--abort', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'merge', 'origin/main', '--no-edit', chdir: worktree.path)
          .and_return(['', 'conflict', failure_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'diff', '--name-only', '--diff-filter=U', chdir: worktree.path)
          .and_return(["file.rb\n", '', success_status], ['', '', success_status])
        allow(claude).to receive(:run_agent)
          .and_return(Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Resolved'))
        allow(Open3).to receive(:capture3)
          .with('git', 'commit', '--no-edit', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('bundle', 'exec', 'rspec', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'push', '-u', 'origin', worktree.branch, chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(claude).to receive(:run_agent)
          .with('merger', anything, chdir: worktree.path)
          .and_return(Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Merged'))
      end

      it 'returns true' do
        expect(manager.merge(42, worktree)).to be true
      end

      it 'logs success' do
        manager.merge(42, worktree)

        expect(logger).to have_received(:info).with('Merge conflicts resolved by agent')
      end
    end
    context 'when tests fail after rebase' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'fetch', 'origin', 'main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', 'origin/main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('bundle', 'exec', 'rspec', chdir: worktree.path)
          .and_return(['', 'failures', failure_status])
      end

      it 'returns false' do
        expect(manager.merge(42, worktree)).to be false
      end
    end

    context 'when push fails' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'fetch', 'origin', 'main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', 'origin/main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('bundle', 'exec', 'rspec', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'push', '-u', 'origin', worktree.branch, chdir: worktree.path)
          .and_return(['', 'rejected', failure_status])
      end

      it 'returns false' do
        expect(manager.merge(42, worktree)).to be false
      end
    end

    context 'when git add fails during commit_uncommitted_changes' do
      before do
        # Dirty worktree
        allow(Open3).to receive(:capture3)
          .with('git', 'status', '--porcelain', chdir: worktree.path)
          .and_return(["M  some_file.rb\n", '', success_status])

        allow(Open3).to receive(:capture3)
          .with('git', 'add', '-A', chdir: worktree.path)
          .and_return(['', 'error: unable to index', failure_status])

        # Rest of merge flow succeeds
        allow(Open3).to receive(:capture3)
          .with('git', 'fetch', 'origin', 'main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', 'origin/main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('bundle', 'exec', 'rspec', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'push', '-u', 'origin', worktree.branch, chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(claude).to receive(:run_agent)
          .and_return(Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Merged'))
      end

      it 'logs a warning and skips commit' do
        manager.merge(42, worktree)

        expect(logger).to have_received(:warn).with(/git add failed/)
        expect(Open3).not_to have_received(:capture3)
          .with('git', 'commit', '-m', anything, chdir: worktree.path)
      end

      it 'continues with the merge flow' do
        expect(manager.merge(42, worktree)).to be true
      end
    end

    context 'when git fetch origin main fails' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'fetch', 'origin', 'main', chdir: worktree.path)
          .and_return(['', 'fatal: could not read from remote', failure_status])
      end

      it 'returns false' do
        expect(manager.merge(42, worktree)).to be false
      end

      it 'logs an error' do
        manager.merge(42, worktree)

        expect(logger).to have_received(:error).with(/git fetch origin main failed/)
      end
    end

    context 'when worktree has uncommitted changes' do
      before do
        # Dirty worktree
        allow(Open3).to receive(:capture3)
          .with('git', 'status', '--porcelain', chdir: worktree.path)
          .and_return(["M  some_file.rb\n?? new_file.rb\n", '', success_status])

        allow(Open3).to receive(:capture3)
          .with('git', 'add', '-A', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'commit', '-m', 'chore: uncommitted pipeline changes for issue #42', chdir: worktree.path)
          .and_return(['', '', success_status])

        # Rest of merge flow succeeds
        allow(Open3).to receive(:capture3)
          .with('git', 'fetch', 'origin', 'main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', 'origin/main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('bundle', 'exec', 'rspec', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'push', '-u', 'origin', worktree.branch, chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(claude).to receive(:run_agent)
          .and_return(Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Merged'))
      end

      it 'commits changes before rebase' do
        expect(Open3).to receive(:capture3)
          .with('git', 'add', '-A', chdir: worktree.path)
          .ordered
        expect(Open3).to receive(:capture3)
          .with('git', 'commit', '-m', 'chore: uncommitted pipeline changes for issue #42', chdir: worktree.path)
          .ordered

        manager.merge(42, worktree)
      end

      it 'returns true when merge succeeds' do
        expect(manager.merge(42, worktree)).to be true
      end
    end
  end

  describe '#create_pr_only' do
    let(:success_status) { instance_double(Process::Status, success?: true) }
    let(:failure_status) { instance_double(Process::Status, success?: false) }

    before do
      allow(Open3).to receive(:capture3)
        .with('git', 'status', '--porcelain', chdir: worktree.path)
        .and_return(['', '', success_status])
    end

    context 'when everything succeeds' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'fetch', 'origin', 'main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', 'origin/main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('bundle', 'exec', 'rspec', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'push', '-u', 'origin', worktree.branch, chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(issues).to receive(:view)
          .with(42, fields: 'title')
          .and_return({ 'title' => 'Fix the bug' })
        allow(Open3).to receive(:capture3)
          .with('gh', 'pr', 'create', '--title', anything, '--body', anything,
                '--head', worktree.branch, chdir: worktree.path)
          .and_return(["https://github.com/owner/repo/pull/99\n", '', success_status])
      end

      it 'returns the PR number' do
        expect(manager.create_pr_only(42, worktree)).to eq(99)
      end

      it 'creates the PR with the correct branch head' do
        expect(Open3).to receive(:capture3)
          .with('gh', 'pr', 'create', '--title', anything, '--body', anything,
                '--head', 'auto/issue-42-abc123', chdir: worktree.path)
          .and_return(["https://github.com/owner/repo/pull/99\n", '', success_status])

        manager.create_pr_only(42, worktree)
      end
    end

    context 'when git fetch fails' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'fetch', 'origin', 'main', chdir: worktree.path)
          .and_return(['', 'fatal: could not read from remote', failure_status])
      end

      it 'returns nil' do
        expect(manager.create_pr_only(42, worktree)).to be_nil
      end

      it 'logs an error about fetch failure' do
        manager.create_pr_only(42, worktree)

        expect(logger).to have_received(:error).with(/git fetch origin main failed/)
      end
    end

    context 'when rebase fails' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'fetch', 'origin', 'main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', 'origin/main', chdir: worktree.path)
          .and_return(['', 'conflict', failure_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', '--abort', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'merge', 'origin/main', '--no-edit', chdir: worktree.path)
          .and_return(['', 'conflict', failure_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'diff', '--name-only', '--diff-filter=U', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'merge', '--abort', chdir: worktree.path)
          .and_return(['', '', success_status])
      end

      it 'returns nil' do
        expect(manager.create_pr_only(42, worktree)).to be_nil
      end
    end

    context 'when push fails' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'fetch', 'origin', 'main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', 'origin/main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('bundle', 'exec', 'rspec', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'push', '-u', 'origin', worktree.branch, chdir: worktree.path)
          .and_return(['', 'rejected', failure_status])
      end

      it 'returns nil' do
        expect(manager.create_pr_only(42, worktree)).to be_nil
      end
    end

    context 'when PR creation fails' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'fetch', 'origin', 'main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', 'origin/main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('bundle', 'exec', 'rspec', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'push', '-u', 'origin', worktree.branch, chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(issues).to receive(:view)
          .with(42, fields: 'title')
          .and_return({ 'title' => 'Fix the bug' })
        allow(Open3).to receive(:capture3)
          .with('gh', 'pr', 'create', any_args, chdir: worktree.path)
          .and_return(['', 'error', failure_status])
      end

      it 'returns nil' do
        expect(manager.create_pr_only(42, worktree)).to be_nil
      end
    end
  end
end
