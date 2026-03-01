# frozen_string_literal: true

require 'spec_helper'
require 'dry/cli'
require 'ocak/commands/resume'

RSpec.describe Ocak::Commands::Resume do
  subject(:command) { described_class.new }

  let(:config) do
    instance_double(Ocak::Config,
                    project_dir: '/project',
                    label_ready: 'auto-ready',
                    label_in_progress: 'in-progress',
                    label_completed: 'completed',
                    label_failed: 'pipeline-failed',
                    log_dir: 'logs/pipeline',
                    poll_interval: 1,
                    max_parallel: 2,
                    max_issues_per_run: 5,
                    cost_budget: nil,
                    worktree_dir: '.claude/worktrees',
                    test_command: nil,
                    lint_command: nil,
                    lint_check_command: nil,
                    setup_command: nil,
                    language: 'ruby',
                    issue_backend: 'github',
                    steps: [
                      { 'agent' => 'implementer', 'role' => 'implement' },
                      { 'agent' => 'reviewer', 'role' => 'review' }
                    ])
  end

  let(:saved_state) do
    {
      completed_steps: [0],
      worktree_path: '/project/.claude/worktrees/issue-42',
      branch: 'auto/issue-42-abc'
    }
  end

  let(:pipeline_state) { instance_double(Ocak::PipelineState) }
  let(:runner) { instance_double(Ocak::PipelineRunner) }
  let(:logger) { instance_double(Ocak::PipelineLogger, info: nil, warn: nil, error: nil, log_file_path: nil) }
  let(:claude) { instance_double(Ocak::ClaudeRunner) }
  let(:issues) { instance_double(Ocak::IssueFetcher) }
  let(:success_result) { Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Done') }

  before do
    allow(Ocak::Config).to receive(:load).and_return(config)
    allow(Ocak::PipelineState).to receive(:new).and_return(pipeline_state)
    allow(Ocak::PipelineLogger).to receive(:new).and_return(logger)
    allow(Ocak::ClaudeRunner).to receive(:new).and_return(claude)
    allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
    allow(Dir).to receive(:exist?).and_call_original
    allow(Dir).to receive(:exist?).with('/project/.claude/worktrees/issue-42').and_return(true)
  end

  context 'with saved state' do
    before do
      allow(pipeline_state).to receive(:load).with(42).and_return(saved_state)
      allow(issues).to receive(:transition)
      allow(issues).to receive(:comment)
    end

    it 'prints resume info and runs pipeline' do
      allow(Ocak::PipelineRunner).to receive(:new).and_return(runner)
      allow(runner).to receive(:run_pipeline).and_return({ success: true })

      merger = instance_double(Ocak::MergeManager)
      allow(Ocak::MergeManager).to receive(:new).and_return(merger)
      allow(merger).to receive(:merge).and_return(true)

      expect { command.call(issue: '42') }.to output(/Resuming issue #42/).to_stdout
    end
  end

  context 'with --dry-run' do
    before do
      allow(pipeline_state).to receive(:load).with(42).and_return(saved_state)
    end

    it 'prints which steps would re-run and exits without executing' do
      expect { command.call(issue: '42', dry_run: true) }.to output(
        /\[DRY RUN\].*implement \(implementer\).*skip \(completed\).*review \(reviewer\).*run/m
      ).to_stdout
    end

    it 'does not transition labels or run pipeline' do
      allow(Ocak::PipelineRunner).to receive(:new)

      command.call(issue: '42', dry_run: true)

      expect(Ocak::PipelineRunner).not_to have_received(:new)
    end
  end

  context 'without saved state' do
    before do
      allow(pipeline_state).to receive(:load).with(42).and_return(nil)
    end

    it 'exits with error when no saved state exists' do
      expect { command.call(issue: '42') }.to raise_error(SystemExit)
    end
  end

  context 'when worktree gone and branch checkout fails' do
    let(:saved_state_no_worktree) do
      {
        completed_steps: [0],
        worktree_path: '/project/.claude/worktrees/issue-42',
        branch: 'auto/issue-42-abc',
        issue_number: 42
      }
    end

    let(:worktree_obj) do
      Ocak::WorktreeManager::Worktree.new(
        path: '/project/.claude/worktrees/issue-42-new',
        branch: 'auto/issue-42-new',
        issue_number: 42
      )
    end

    before do
      allow(pipeline_state).to receive(:load).with(42).and_return(saved_state_no_worktree)
      allow(Dir).to receive(:exist?).with('/project/.claude/worktrees/issue-42').and_return(false)
      # Branch exists
      allow(Open3).to receive(:capture3)
        .with('git', 'rev-parse', '--verify', 'auto/issue-42-abc', chdir: '/project')
        .and_return(['abc123', '', instance_double(Process::Status, success?: true)])
      # Worktree created
      worktrees = instance_double(Ocak::WorktreeManager)
      allow(Ocak::WorktreeManager).to receive(:new).and_return(worktrees)
      allow(worktrees).to receive(:create).and_return(worktree_obj)
      # Checkout fails
      allow(Open3).to receive(:capture3)
        .with('git', 'checkout', 'auto/issue-42-abc', chdir: worktree_obj.path)
        .and_return(['', 'error: pathspec did not match', instance_double(Process::Status, success?: false)])
    end

    it 'exits with error' do
      expect { command.call(issue: '42') }.to raise_error(SystemExit)
    end

    it 'warns about the failed checkout' do
      expect { command.call(issue: '42') }.to raise_error(SystemExit).and output(
        /Failed to checkout branch/
      ).to_stderr
    end
  end

  context 'when branch name is unsafe' do
    let(:saved_state_bad_branch) do
      {
        completed_steps: [0],
        worktree_path: '/project/.claude/worktrees/issue-42',
        branch: '--upload-pack=/tmp/evil',
        issue_number: 42
      }
    end

    before do
      allow(pipeline_state).to receive(:load).with(42).and_return(saved_state_bad_branch)
      allow(Dir).to receive(:exist?).with('/project/.claude/worktrees/issue-42').and_return(false)
    end

    it 'exits with error' do
      expect { command.call(issue: '42') }.to raise_error(SystemExit)
    end

    it 'warns about the unsafe branch name' do
      expect { command.call(issue: '42') }.to raise_error(SystemExit).and output(
        /Unsafe branch name/
      ).to_stderr
    end

    it 'does not call git rev-parse' do
      allow(Open3).to receive(:capture3)
      begin
        command.call(issue: '42')
      rescue SystemExit
        # expected
      end

      expect(Open3).not_to have_received(:capture3)
        .with('git', 'rev-parse', '--verify', anything, anything)
    end
  end

  it 'exits with error on ConfigNotFound' do
    allow(Ocak::Config).to receive(:load).and_raise(Ocak::Config::ConfigNotFound, 'not found')

    expect { command.call(issue: '42') }.to raise_error(SystemExit)
  end
end
