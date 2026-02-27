# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Ocak::WorktreeManager do
  let(:config) do
    instance_double(Ocak::Config,
                    project_dir: '/project',
                    worktree_dir: '.claude/worktrees')
  end

  subject(:manager) { described_class.new(config: config) }

  describe '#create' do
    it 'creates a worktree with the correct branch naming' do
      allow(FileUtils).to receive(:mkdir_p)
      allow(Open3).to receive(:capture3)
        .with('git', 'worktree', 'add', '-b', anything, anything, 'main', chdir: '/project')
        .and_return(['', '', instance_double(Process::Status, success?: true)])

      worktree = manager.create(42)

      expect(worktree.branch).to match(%r{\Aauto/issue-42-[a-f0-9]{8}\z})
      expect(worktree.path).to eq('/project/.claude/worktrees/issue-42')
      expect(worktree.issue_number).to eq(42)
    end

    it 'raises on failure' do
      allow(FileUtils).to receive(:mkdir_p)
      allow(Open3).to receive(:capture3)
        .and_return(['', 'fatal: error', instance_double(Process::Status, success?: false)])

      expect { manager.create(42) }.to raise_error(Ocak::WorktreeManager::WorktreeError)
    end

    it 'runs setup command after creating worktree' do
      allow(FileUtils).to receive(:mkdir_p)
      allow(Open3).to receive(:capture3)
        .with('git', 'worktree', 'add', '-b', anything, anything, 'main', chdir: '/project')
        .and_return(['', '', instance_double(Process::Status, success?: true)])
      allow(Open3).to receive(:capture3)
        .with('bundle', 'install', chdir: '/project/.claude/worktrees/issue-42')
        .and_return(['', '', instance_double(Process::Status, success?: true)])

      worktree = manager.create(42, setup_command: 'bundle install')

      expect(worktree.path).to eq('/project/.claude/worktrees/issue-42')
      expect(Open3).to have_received(:capture3)
        .with('bundle', 'install', chdir: '/project/.claude/worktrees/issue-42')
    end

    it 'raises when setup command fails' do
      allow(FileUtils).to receive(:mkdir_p)
      allow(Open3).to receive(:capture3)
        .with('git', 'worktree', 'add', '-b', anything, anything, 'main', chdir: '/project')
        .and_return(['', '', instance_double(Process::Status, success?: true)])
      allow(Open3).to receive(:capture3)
        .with('bundle', 'install', chdir: '/project/.claude/worktrees/issue-42')
        .and_return(['', 'install failed', instance_double(Process::Status, success?: false)])

      expect { manager.create(42, setup_command: 'bundle install') }
        .to raise_error(Ocak::WorktreeManager::WorktreeError, /Setup command failed/)
    end
  end

  describe '#remove' do
    it 'removes the worktree and prunes' do
      worktree = Ocak::WorktreeManager::Worktree.new(
        path: '/project/.claude/worktrees/issue-42',
        branch: 'auto/issue-42-abc123',
        issue_number: 42
      )

      expect(Open3).to receive(:capture3)
        .with('git', 'worktree', 'remove', '--force', worktree.path, chdir: '/project')
        .and_return(['', '', instance_double(Process::Status, success?: true)])

      expect(Open3).to receive(:capture3)
        .with('git', 'worktree', 'prune', chdir: '/project')
        .and_return(['', '', instance_double(Process::Status, success?: true)])

      manager.remove(worktree)
    end
  end

  describe '#list' do
    it 'parses porcelain worktree list' do
      porcelain_output = <<~OUTPUT
        worktree /project
        branch refs/heads/main

        worktree /project/.claude/worktrees/issue-42
        branch refs/heads/auto/issue-42-abc123

      OUTPUT

      allow(Open3).to receive(:capture3)
        .with('git', 'worktree', 'list', '--porcelain', chdir: '/project')
        .and_return([porcelain_output, '', instance_double(Process::Status, success?: true)])

      worktrees = manager.list
      expect(worktrees.size).to eq(2)
      expect(worktrees[1][:branch]).to eq('auto/issue-42-abc123')
    end

    it 'returns empty array on failure' do
      allow(Open3).to receive(:capture3)
        .and_return(['', 'error', instance_double(Process::Status, success?: false)])

      expect(manager.list).to eq([])
    end
  end
end
