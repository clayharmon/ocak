# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Ocak::LocalMergeManager do
  let(:config) do
    instance_double(Ocak::Config,
                    project_dir: '/project',
                    test_command: 'bundle exec rspec')
  end

  let(:logger) do
    instance_double(Ocak::PipelineLogger, info: nil, warn: nil, error: nil)
  end

  let(:issues) do
    instance_double(Ocak::LocalIssueFetcher)
  end

  let(:worktree) do
    Ocak::WorktreeManager::Worktree.new(
      path: '/project/.claude/worktrees/issue-42',
      branch: 'auto/issue-42-abc123',
      issue_number: 42
    )
  end

  subject(:manager) { described_class.new(config: config, logger: logger, issues: issues) }

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
          .with('git', 'rebase', 'main', chdir: worktree.path)
          .and_return(['', '', success_status])

        # Tests
        allow(Open3).to receive(:capture3)
          .with('bundle', 'exec', 'rspec', chdir: worktree.path)
          .and_return(['', '', success_status])

        # Checkout main
        allow(Open3).to receive(:capture3)
          .with('git', 'checkout', 'main', chdir: config.project_dir)
          .and_return(['', '', success_status])

        # Merge
        allow(Open3).to receive(:capture3)
          .with('git', 'merge', worktree.branch, '--ff-only', chdir: config.project_dir)
          .and_return(['', '', success_status])

        # Delete branch
        allow(Open3).to receive(:capture3)
          .with('git', 'branch', '-d', worktree.branch, chdir: config.project_dir)
          .and_return(['', '', success_status])
      end

      it 'returns true' do
        expect(manager.merge(42, worktree)).to be true
      end

      it 'logs success message' do
        manager.merge(42, worktree)
        expect(logger).to have_received(:info).with('Issue #42 merged to main (local)')
      end

      it 'deletes the branch after merge' do
        expect(Open3).to receive(:capture3)
          .with('git', 'branch', '-d', worktree.branch, chdir: config.project_dir)

        manager.merge(42, worktree)
      end
    end

    context 'when rebase fails' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', 'main', chdir: worktree.path)
          .and_return(['', 'conflict', failure_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', '--abort', chdir: worktree.path)
          .and_return(['', '', success_status])
      end

      it 'returns false' do
        expect(manager.merge(42, worktree)).to be false
      end

      it 'aborts the rebase' do
        expect(Open3).to receive(:capture3)
          .with('git', 'rebase', '--abort', chdir: worktree.path)

        manager.merge(42, worktree)
      end

      it 'logs error message' do
        manager.merge(42, worktree)
        expect(logger).to have_received(:error).with('Rebase failed for issue #42')
      end
    end

    context 'when tests fail after rebase' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', 'main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('bundle', 'exec', 'rspec', chdir: worktree.path)
          .and_return(['', 'test failures', failure_status])
      end

      it 'returns false' do
        expect(manager.merge(42, worktree)).to be false
      end

      it 'logs error message' do
        manager.merge(42, worktree)
        expect(logger).to have_received(:error).with('Tests failed after rebase for issue #42')
      end
    end

    context 'when checkout main fails' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', 'main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('bundle', 'exec', 'rspec', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'checkout', 'main', chdir: config.project_dir)
          .and_return(['', 'checkout error', failure_status])
      end

      it 'returns false' do
        expect(manager.merge(42, worktree)).to be false
      end

      it 'logs error message' do
        manager.merge(42, worktree)
        expect(logger).to have_received(:error).with('Merge to main failed for issue #42')
      end
    end

    context 'when fast-forward merge fails' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', 'main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('bundle', 'exec', 'rspec', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'checkout', 'main', chdir: config.project_dir)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'merge', worktree.branch, '--ff-only', chdir: config.project_dir)
          .and_return(['', 'merge error', failure_status])
      end

      it 'returns false' do
        expect(manager.merge(42, worktree)).to be false
      end

      it 'logs error message' do
        manager.merge(42, worktree)
        expect(logger).to have_received(:error).with('Merge to main failed for issue #42')
      end
    end

    context 'when no test command is configured' do
      let(:config) do
        instance_double(Ocak::Config,
                        project_dir: '/project',
                        test_command: nil)
      end

      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', 'main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'checkout', 'main', chdir: config.project_dir)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'merge', worktree.branch, '--ff-only', chdir: config.project_dir)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'branch', '-d', worktree.branch, chdir: config.project_dir)
          .and_return(['', '', success_status])
      end

      it 'skips test verification' do
        expect(Open3).not_to receive(:capture3)
          .with('bundle', 'exec', 'rspec', anything)

        manager.merge(42, worktree)
      end

      it 'returns true' do
        expect(manager.merge(42, worktree)).to be true
      end
    end

    context 'when worktree has uncommitted changes' do
      before do
        # Dirty worktree
        allow(Open3).to receive(:capture3)
          .with('git', 'status', '--porcelain', chdir: worktree.path)
          .and_return(["M  some_file.rb\n", '', success_status])

        allow(Open3).to receive(:capture3)
          .with('git', 'add', '-A', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'commit', '-m', 'chore: uncommitted pipeline changes for issue #42', chdir: worktree.path)
          .and_return(['', '', success_status])

        # Rest of merge flow succeeds
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', 'main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('bundle', 'exec', 'rspec', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'checkout', 'main', chdir: config.project_dir)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'merge', worktree.branch, '--ff-only', chdir: config.project_dir)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'branch', '-d', worktree.branch, chdir: config.project_dir)
          .and_return(['', '', success_status])
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

    context 'when branch deletion fails' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', 'main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('bundle', 'exec', 'rspec', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'checkout', 'main', chdir: config.project_dir)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'merge', worktree.branch, '--ff-only', chdir: config.project_dir)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'branch', '-d', worktree.branch, chdir: config.project_dir)
          .and_raise(StandardError.new('branch deletion failed'))
      end

      it 'logs a warning but still returns true' do
        expect(manager.merge(42, worktree)).to be true
        expect(logger).to have_received(:warn).with(/Failed to delete branch/)
      end
    end

    context 'when test command uses shell syntax' do
      let(:config) do
        instance_double(Ocak::Config,
                        project_dir: '/project',
                        test_command: 'npm test -- --coverage')
      end

      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'rebase', 'main', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('npm', 'test', '--', '--coverage', chdir: worktree.path)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'checkout', 'main', chdir: config.project_dir)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'merge', worktree.branch, '--ff-only', chdir: config.project_dir)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'branch', '-d', worktree.branch, chdir: config.project_dir)
          .and_return(['', '', success_status])
      end

      it 'splits test command with Shellwords.shellsplit' do
        expect(Open3).to receive(:capture3)
          .with('npm', 'test', '--', '--coverage', chdir: worktree.path)

        manager.merge(42, worktree)
      end
    end
  end

  describe '#create_pr_only' do
    it 'logs a warning about manual_review not being supported' do
      manager.create_pr_only(42, worktree)
      expect(logger).to have_received(:warn)
        .with('manual_review is not supported in fully local mode for issue #42')
    end

    it 'returns nil' do
      expect(manager.create_pr_only(42, worktree)).to be_nil
    end
  end
end
