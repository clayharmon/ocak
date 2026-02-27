# frozen_string_literal: true

require 'spec_helper'
require 'ocak/pipeline_runner'

RSpec.describe Ocak::PipelineRunner do
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
                    worktree_dir: '.claude/worktrees',
                    test_command: nil,
                    lint_command: nil,
                    lint_check_command: nil,
                    setup_command: nil,
                    language: 'ruby',
                    steps: [
                      { 'agent' => 'implementer', 'role' => 'implement' },
                      { 'agent' => 'reviewer', 'role' => 'review' },
                      { 'agent' => 'implementer', 'role' => 'fix', 'condition' => 'has_findings' }
                    ])
  end

  let(:logger) { instance_double(Ocak::PipelineLogger, info: nil, warn: nil, error: nil, log_file_path: nil) }
  let(:claude) { instance_double(Ocak::ClaudeRunner) }
  let(:issues) { instance_double(Ocak::IssueFetcher) }

  let(:success_result) { Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Done') }
  let(:failure_result) { Ocak::ClaudeRunner::AgentResult.new(success: false, output: 'Error') }
  let(:blocking_result) { Ocak::ClaudeRunner::AgentResult.new(success: true, output: "Found \u{1F534} issue") }

  before do
    allow(Ocak::PipelineLogger).to receive(:new).and_return(logger)
    allow(Ocak::ClaudeRunner).to receive(:new).and_return(claude)
    allow(FileUtils).to receive(:mkdir_p)
  end

  describe 'single issue mode' do
    subject(:runner) { described_class.new(config: config, options: { single: 42 }) }

    it 'runs pipeline and transitions labels on success' do
      allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
      allow(issues).to receive(:transition)
      allow(claude).to receive(:run_agent).and_return(success_result)

      runner.run

      expect(issues).to have_received(:transition).with(42, from: 'auto-ready', to: 'in-progress')
      expect(issues).to have_received(:transition).with(42, from: 'in-progress', to: 'completed')
    end

    it 'transitions to failed on pipeline failure' do
      allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
      allow(issues).to receive(:transition)
      allow(issues).to receive(:comment)
      allow(claude).to receive(:run_agent).with('implementer', anything, chdir: anything).and_return(failure_result)

      runner.run

      expect(issues).to have_received(:transition).with(42, from: 'in-progress', to: 'pipeline-failed')
    end

    it 'skips execution in dry run mode' do
      runner_dry = described_class.new(config: config, options: { single: 42, dry_run: true })
      allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)

      runner_dry.run

      expect(claude).not_to have_received(:run_agent) if claude.respond_to?(:run_agent)
    end
  end

  describe 'pipeline step conditions' do
    subject(:runner) { described_class.new(config: config, options: { single: 10 }) }

    it 'skips fix step when no blocking findings' do
      allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
      allow(issues).to receive(:transition)

      # Implement succeeds
      allow(claude).to receive(:run_agent).with('implementer', anything, chdir: anything).and_return(success_result)
      # Review passes (no findings)
      allow(claude).to receive(:run_agent).with('reviewer', anything, chdir: anything).and_return(success_result)
      # Merger
      allow(claude).to receive(:run_agent).with('merger', anything, chdir: anything).and_return(success_result)

      runner.run

      # Fix step should be skipped — implementer called once for implement, not again for fix
      expect(claude).to have_received(:run_agent).with('implementer', anything, chdir: anything).once
    end

    it 'runs fix step when blocking findings present' do
      steps_with_fix = [
        { 'agent' => 'implementer', 'role' => 'implement' },
        { 'agent' => 'reviewer', 'role' => 'review' },
        { 'agent' => 'implementer', 'role' => 'fix', 'condition' => 'has_findings' },
        { 'agent' => 'merger', 'role' => 'merge' }
      ]
      allow(config).to receive(:steps).and_return(steps_with_fix)
      allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
      allow(issues).to receive(:transition)

      # Implement succeeds
      allow(claude).to receive(:run_agent).with('implementer', /Implement/, chdir: anything)
                                          .and_return(success_result)
      # Review finds blocking issues
      allow(claude).to receive(:run_agent).with('reviewer', anything, chdir: anything)
                                          .and_return(blocking_result)
      # Fix runs
      allow(claude).to receive(:run_agent).with('implementer', /Fix/, chdir: anything)
                                          .and_return(success_result)
      # Merger
      allow(claude).to receive(:run_agent).with('merger', anything, chdir: anything)
                                          .and_return(success_result)

      runner.run

      expect(claude).to have_received(:run_agent).with('implementer', /Fix/, chdir: anything).once
    end
  end

  describe 'planner' do
    subject(:runner) { described_class.new(config: config, options: { once: true }) }

    it 'falls back to sequential batches when planner fails' do
      allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
      allow(issues).to receive(:fetch_ready).and_return([
                                                          { 'number' => 1, 'title' => 'A' },
                                                          { 'number' => 2, 'title' => 'B' }
                                                        ])
      allow(issues).to receive(:transition)
      allow(issues).to receive(:comment)

      allow(claude).to receive(:run_agent).with('planner', anything).and_return(failure_result)
      allow(claude).to receive(:run_agent).with(anything, anything, chdir: anything).and_return(failure_result)

      runner.run

      expect(claude).to have_received(:run_agent).with('planner', anything)
    end

    it 'returns sequential batches for single issue' do
      allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
      allow(issues).to receive(:fetch_ready).and_return([{ 'number' => 1, 'title' => 'A' }])
      allow(issues).to receive(:transition)
      allow(issues).to receive(:comment)
      allow(claude).to receive(:run_agent).and_return(failure_result)

      runner.run

      # Should not call planner for single issue
      expect(claude).not_to have_received(:run_agent).with('planner', anything)
    end
  end
end
