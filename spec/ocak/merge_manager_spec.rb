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

  let(:worktree) do
    Ocak::WorktreeManager::Worktree.new(
      path: '/project/.claude/worktrees/issue-42',
      branch: 'auto/issue-42-abc123',
      issue_number: 42
    )
  end

  subject(:manager) { described_class.new(config: config, claude: claude, logger: logger) }

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
end
