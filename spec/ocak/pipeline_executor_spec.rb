# frozen_string_literal: true

require 'spec_helper'
require 'ocak/pipeline_executor'

RSpec.describe Ocak::PipelineExecutor do
  let(:config) do
    instance_double(Ocak::Config,
                    project_dir: '/project',
                    log_dir: 'logs/pipeline',
                    cost_budget: nil,
                    test_command: nil,
                    lint_check_command: nil,
                    manual_review: false,
                    language: 'ruby',
                    steps: [
                      { 'agent' => 'implementer', 'role' => 'implement' },
                      { 'agent' => 'reviewer', 'role' => 'review' },
                      { 'agent' => 'implementer', 'role' => 'fix', 'condition' => 'has_findings' }
                    ])
  end

  let(:logger) { instance_double(Ocak::PipelineLogger, info: nil, warn: nil, error: nil, log_file_path: nil) }
  let(:claude) { instance_double(Ocak::ClaudeRunner) }
  let(:pipeline_state) { instance_double(Ocak::PipelineState, save: nil, delete: nil, load: nil) }

  let(:success_result) { Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Done') }
  let(:failure_result) { Ocak::ClaudeRunner::AgentResult.new(success: false, output: 'Error') }
  let(:blocking_result) { Ocak::ClaudeRunner::AgentResult.new(success: true, output: "Found \u{1F534} issue") }

  subject(:executor) { described_class.new(config: config) }

  before do
    allow(Ocak::PipelineState).to receive(:new).and_return(pipeline_state)
    allow(Open3).to receive(:capture3)
      .with('git', 'rev-parse', '--abbrev-ref', 'HEAD', chdir: anything)
      .and_return(["main\n", '', instance_double(Process::Status, success?: true)])
    allow(FileUtils).to receive(:mkdir_p)
  end

  describe '#run_pipeline' do
    it 'executes all steps and returns success' do
      allow(claude).to receive(:run_agent).and_return(success_result)

      result = executor.run_pipeline(42, logger: logger, claude: claude)

      expect(result[:success]).to be true
      expect(claude).to have_received(:run_agent).with('implementer', anything, chdir: '/project')
      expect(claude).to have_received(:run_agent).with('reviewer', anything, chdir: '/project')
    end

    it 'uses provided chdir' do
      allow(claude).to receive(:run_agent).and_return(success_result)

      executor.run_pipeline(42, logger: logger, claude: claude, chdir: '/worktree')

      expect(claude).to have_received(:run_agent).with('implementer', anything, chdir: '/worktree')
    end

    it 'returns failure when implement step fails' do
      allow(claude).to receive(:run_agent).with('implementer', anything, chdir: anything)
                                          .and_return(failure_result)

      result = executor.run_pipeline(42, logger: logger, claude: claude)

      expect(result[:success]).to be false
      expect(result[:phase]).to eq('implement')
    end

    it 'deletes pipeline state on success' do
      allow(claude).to receive(:run_agent).and_return(success_result)

      executor.run_pipeline(42, logger: logger, claude: claude)

      expect(pipeline_state).to have_received(:delete).with(42)
    end

    it 'saves progress after each step' do
      allow(claude).to receive(:run_agent).and_return(success_result)

      executor.run_pipeline(42, logger: logger, claude: claude)

      expect(pipeline_state).to have_received(:save).at_least(:twice)
    end

    it 'skips already-completed steps' do
      allow(claude).to receive(:run_agent).and_return(success_result)

      executor.run_pipeline(42, logger: logger, claude: claude, skip_steps: [0])

      expect(claude).not_to have_received(:run_agent).with('implementer', /Implement/, chdir: anything)
      expect(claude).to have_received(:run_agent).with('reviewer', anything, chdir: anything)
    end
  end

  describe 'step conditions' do
    it 'skips fix step when no blocking findings' do
      allow(claude).to receive(:run_agent).with('implementer', anything, chdir: anything)
                                          .and_return(success_result)
      allow(claude).to receive(:run_agent).with('reviewer', anything, chdir: anything)
                                          .and_return(success_result)

      executor.run_pipeline(10, logger: logger, claude: claude)

      expect(claude).to have_received(:run_agent).with('implementer', anything, chdir: anything).once
    end

    it 'runs fix step when blocking findings present' do
      steps = [
        { 'agent' => 'implementer', 'role' => 'implement' },
        { 'agent' => 'reviewer', 'role' => 'review' },
        { 'agent' => 'implementer', 'role' => 'fix', 'condition' => 'has_findings' }
      ]
      allow(config).to receive(:steps).and_return(steps)

      allow(claude).to receive(:run_agent).with('implementer', /Implement/, chdir: anything)
                                          .and_return(success_result)
      allow(claude).to receive(:run_agent).with('reviewer', anything, chdir: anything)
                                          .and_return(blocking_result)
      allow(claude).to receive(:run_agent).with('implementer', /Fix/, chdir: anything)
                                          .and_return(success_result)

      executor.run_pipeline(10, logger: logger, claude: claude)

      expect(claude).to have_received(:run_agent).with('implementer', /Fix/, chdir: anything).once
    end

    it 'skips had_fixes condition when no fixes were made' do
      steps = [
        { 'agent' => 'implementer', 'role' => 'implement' },
        { 'agent' => 'verifier', 'role' => 'verify', 'condition' => 'had_fixes' }
      ]
      allow(config).to receive(:steps).and_return(steps)
      allow(claude).to receive(:run_agent).and_return(success_result)

      executor.run_pipeline(10, logger: logger, claude: claude)

      expect(claude).not_to have_received(:run_agent).with('verifier', anything, chdir: anything)
    end
  end

  describe 'complexity-based step skipping' do
    let(:steps_with_complexity) do
      [
        { 'agent' => 'implementer', 'role' => 'implement' },
        { 'agent' => 'reviewer', 'role' => 'review' },
        { 'agent' => 'documenter', 'role' => 'document', 'complexity' => 'full' },
        { 'agent' => 'auditor', 'role' => 'audit', 'complexity' => 'full' }
      ]
    end

    before do
      allow(config).to receive(:steps).and_return(steps_with_complexity)
      allow(claude).to receive(:run_agent).and_return(success_result)
    end

    it 'skips full-complexity steps for simple issues' do
      executor.run_pipeline(10, logger: logger, claude: claude, complexity: 'simple')

      expect(claude).not_to have_received(:run_agent).with('documenter', anything, chdir: anything)
      expect(claude).not_to have_received(:run_agent).with('auditor', anything, chdir: anything)
    end

    it 'runs full-complexity steps for full issues' do
      executor.run_pipeline(10, logger: logger, claude: claude, complexity: 'full')

      expect(claude).to have_received(:run_agent).with('documenter', anything, chdir: anything)
      expect(claude).to have_received(:run_agent).with('auditor', anything, chdir: anything)
    end

    it 'always runs steps without complexity tag for simple issues' do
      executor.run_pipeline(10, logger: logger, claude: claude, complexity: 'simple')

      expect(claude).to have_received(:run_agent).with('implementer', anything, chdir: anything)
      expect(claude).to have_received(:run_agent).with('reviewer', anything, chdir: anything)
    end

    it 'defaults to full complexity' do
      executor.run_pipeline(10, logger: logger, claude: claude)

      expect(claude).to have_received(:run_agent).with('documenter', anything, chdir: anything)
    end
  end

  describe 'manual review mode' do
    let(:steps_with_merge) do
      [
        { 'agent' => 'implementer', 'role' => 'implement' },
        { 'agent' => 'reviewer', 'role' => 'review' },
        { 'agent' => 'merger', 'role' => 'merge' }
      ]
    end

    before do
      allow(config).to receive(:steps).and_return(steps_with_merge)
      allow(config).to receive(:manual_review).and_return(true)
      allow(claude).to receive(:run_agent).and_return(success_result)
    end

    it 'skips the merge step when manual_review is true' do
      executor.run_pipeline(42, logger: logger, claude: claude)

      expect(claude).not_to have_received(:run_agent).with('merger', anything, chdir: anything)
    end

    it 'still runs non-merge steps' do
      executor.run_pipeline(42, logger: logger, claude: claude)

      expect(claude).to have_received(:run_agent).with('implementer', anything, chdir: anything)
      expect(claude).to have_received(:run_agent).with('reviewer', anything, chdir: anything)
    end
  end

  describe 'cost budget' do
    it 'returns failure when cost exceeds budget' do
      allow(config).to receive(:cost_budget).and_return(0.01)
      expensive_result = Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Done', cost_usd: 0.02)
      allow(claude).to receive(:run_agent).and_return(expensive_result)

      result = executor.run_pipeline(42, logger: logger, claude: claude)

      expect(result[:success]).to be false
      expect(result[:phase]).to eq('budget')
    end

    it 'continues when cost is within budget' do
      allow(config).to receive(:cost_budget).and_return(10.0)
      cheap_result = Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Done', cost_usd: 0.01)
      allow(claude).to receive(:run_agent).and_return(cheap_result)

      result = executor.run_pipeline(42, logger: logger, claude: claude)

      expect(result[:success]).to be true
    end

    it 'continues when no budget is set' do
      allow(config).to receive(:cost_budget).and_return(nil)
      allow(claude).to receive(:run_agent).and_return(success_result)

      result = executor.run_pipeline(42, logger: logger, claude: claude)

      expect(result[:success]).to be true
    end
  end

  describe 'final verification' do
    it 'runs final checks when test_command is configured' do
      allow(config).to receive(:test_command).and_return('bundle exec rspec')
      allow(config).to receive(:lint_check_command).and_return(nil)
      allow(claude).to receive(:run_agent).and_return(success_result)
      allow(Open3).to receive(:capture3)
        .with('bundle', 'exec', 'rspec', chdir: '/project')
        .and_return(['', '', instance_double(Process::Status, success?: true)])

      result = executor.run_pipeline(42, logger: logger, claude: claude)

      expect(result[:success]).to be true
    end

    it 'fails when final checks fail after retry' do
      allow(config).to receive(:test_command).and_return('bundle exec rspec')
      allow(config).to receive(:lint_check_command).and_return(nil)
      allow(claude).to receive(:run_agent).and_return(success_result)
      allow(Open3).to receive(:capture3)
        .with('bundle', 'exec', 'rspec', chdir: '/project')
        .and_return(['FAIL', '', instance_double(Process::Status, success?: false)])

      result = executor.run_pipeline(42, logger: logger, claude: claude)

      expect(result[:success]).to be false
      expect(result[:phase]).to eq('final-verify')
    end
  end

  describe '#plan_batches' do
    it 'returns sequential batches for single issue' do
      issues = [{ 'number' => 1, 'title' => 'A' }]

      batches = executor.plan_batches(issues, logger: logger, claude: claude)

      expect(batches.size).to eq(1)
      expect(batches.first['issues'].first['number']).to eq(1)
    end

    it 'falls back to sequential when planner fails' do
      issues = [{ 'number' => 1, 'title' => 'A' }, { 'number' => 2, 'title' => 'B' }]
      allow(claude).to receive(:run_agent).with('planner', anything).and_return(failure_result)

      batches = executor.plan_batches(issues, logger: logger, claude: claude)

      expect(batches.size).to eq(2)
    end
  end
end
