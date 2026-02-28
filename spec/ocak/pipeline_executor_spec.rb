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
                    audit_mode: false,
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

  describe 'audit mode' do
    let(:steps_with_audit_and_merge) do
      [
        { 'agent' => 'implementer', 'role' => 'implement' },
        { 'agent' => 'auditor', 'role' => 'audit' },
        { 'agent' => 'merger', 'role' => 'merge' }
      ]
    end

    before do
      allow(config).to receive(:steps).and_return(steps_with_audit_and_merge)
      allow(config).to receive(:audit_mode).and_return(true)
      allow(claude).to receive(:run_agent).and_return(success_result)
    end

    it 'runs merge when audit is clean' do
      executor.run_pipeline(42, logger: logger, claude: claude)

      expect(claude).to have_received(:run_agent).with('merger', anything, chdir: anything)
    end

    it 'skips merge when audit has BLOCK findings' do
      block_result = Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'BLOCK: security issue')
      allow(claude).to receive(:run_agent).with('auditor', anything, chdir: anything)
                                          .and_return(block_result)

      executor.run_pipeline(42, logger: logger, claude: claude)

      expect(claude).not_to have_received(:run_agent).with('merger', anything, chdir: anything)
    end

    it "skips merge when audit has \u{1F534} findings" do
      allow(claude).to receive(:run_agent).with('auditor', anything, chdir: anything)
                                          .and_return(blocking_result)

      executor.run_pipeline(42, logger: logger, claude: claude)

      expect(claude).not_to have_received(:run_agent).with('merger', anything, chdir: anything)
    end

    it 'runs merge when audit_mode is on but no audit step exists' do
      steps_no_audit = [
        { 'agent' => 'implementer', 'role' => 'implement' },
        { 'agent' => 'merger', 'role' => 'merge' }
      ]
      allow(config).to receive(:steps).and_return(steps_no_audit)

      executor.run_pipeline(42, logger: logger, claude: claude)

      expect(claude).to have_received(:run_agent).with('merger', anything, chdir: anything)
    end

    it 'returns audit_blocked: true when audit has findings' do
      block_result = Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'BLOCK: issue')
      allow(claude).to receive(:run_agent).with('auditor', anything, chdir: anything)
                                          .and_return(block_result)

      result = executor.run_pipeline(42, logger: logger, claude: claude)

      expect(result[:audit_blocked]).to be true
      expect(result[:audit_output]).to match(/BLOCK/)
    end

    it 'returns audit_blocked: false when audit is clean' do
      result = executor.run_pipeline(42, logger: logger, claude: claude)

      expect(result[:audit_blocked]).to be false
      expect(result[:audit_output]).to eq('Done')
    end

    it 'posts skip comment with "audit found blocking issues" reason' do
      issues_fetcher = instance_double(Ocak::IssueFetcher)
      allow(issues_fetcher).to receive(:comment)
      executor_with_issues = described_class.new(config: config, issues: issues_fetcher)

      block_result = Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'BLOCK: issue')
      allow(claude).to receive(:run_agent).with('auditor', anything, chdir: anything)
                                          .and_return(block_result)

      executor_with_issues.run_pipeline(42, logger: logger, claude: claude)

      expect(issues_fetcher).to have_received(:comment)
        .with(42, /\u{23ED}.*\*\*Skipping merge\*\*.*audit found blocking issues/)
    end

    it 'skips merge when both audit_mode and manual_review are on and audit is clean' do
      allow(config).to receive(:manual_review).and_return(true)

      executor.run_pipeline(42, logger: logger, claude: claude)

      expect(claude).not_to have_received(:run_agent).with('merger', anything, chdir: anything)
    end

    it 'treats audit agent failure as blocking' do
      failed = Ocak::ClaudeRunner::AgentResult.new(success: false, output: 'Agent crashed')
      allow(claude).to receive(:run_agent).with('auditor', anything, chdir: anything)
                                          .and_return(failed)

      result = executor.run_pipeline(42, logger: logger, claude: claude)

      expect(result[:audit_blocked]).to be true
      expect(claude).not_to have_received(:run_agent).with('merger', anything, chdir: anything)
    end

    it 'still runs non-merge steps' do
      executor.run_pipeline(42, logger: logger, claude: claude)

      expect(claude).to have_received(:run_agent).with('implementer', anything, chdir: anything)
      expect(claude).to have_received(:run_agent).with('auditor', anything, chdir: anything)
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

  describe 'progress comments' do
    let(:issues_fetcher) { instance_double(Ocak::IssueFetcher) }
    let(:executor_with_issues) { described_class.new(config: config, issues: issues_fetcher) }
    let(:result_with_cost) do
      Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Done', cost_usd: 0.012, duration_ms: 45_000)
    end
    let(:failed_result_with_cost) do
      Ocak::ClaudeRunner::AgentResult.new(success: false, output: 'Error', cost_usd: 0.034, duration_ms: 120_000)
    end

    before do
      allow(issues_fetcher).to receive(:comment)
    end

    it 'posts start comment before step execution' do
      allow(claude).to receive(:run_agent).and_return(result_with_cost)

      executor_with_issues.run_pipeline(42, logger: logger, claude: claude)

      expect(issues_fetcher).to have_received(:comment)
        .with(42, /\u{1F504} \*\*Phase: implement\*\*/)
    end

    it 'posts completion comment after successful step' do
      allow(claude).to receive(:run_agent).and_return(result_with_cost)

      executor_with_issues.run_pipeline(42, logger: logger, claude: claude)

      expect(issues_fetcher).to have_received(:comment)
        .with(42, /\u{2705} \*\*Phase: implement\*\* completed.*45s.*\$0\.012/)
    end

    it 'posts failure comment after failed step' do
      allow(claude).to receive(:run_agent).with('implementer', anything, chdir: anything)
                                          .and_return(failed_result_with_cost)

      executor_with_issues.run_pipeline(42, logger: logger, claude: claude)

      expect(issues_fetcher).to have_received(:comment)
        .with(42, /\u{274C} \*\*Phase: implement\*\* failed.*120s.*\$0\.034/)
    end

    it 'does not post comments for skipped steps' do
      allow(claude).to receive(:run_agent).and_return(result_with_cost)

      executor_with_issues.run_pipeline(42, logger: logger, claude: claude)

      expect(issues_fetcher).not_to have_received(:comment)
        .with(42, /Phase: fix/)
    end

    it 'does not crash when comment posting fails' do
      allow(issues_fetcher).to receive(:comment).and_raise(StandardError, 'network error')
      allow(claude).to receive(:run_agent).and_return(result_with_cost)

      result = executor_with_issues.run_pipeline(42, logger: logger, claude: claude)

      expect(result[:success]).to be true
    end

    it 'works without issues fetcher (nil)' do
      allow(claude).to receive(:run_agent).and_return(success_result)

      result = executor.run_pipeline(42, logger: logger, claude: claude)

      expect(result[:success]).to be true
    end
  end

  describe 'final verification comments' do
    let(:issues_fetcher) { instance_double(Ocak::IssueFetcher) }
    let(:executor_with_issues) { described_class.new(config: config, issues: issues_fetcher) }

    before do
      allow(issues_fetcher).to receive(:comment)
      allow(config).to receive(:test_command).and_return('bundle exec rspec')
      allow(config).to receive(:lint_check_command).and_return(nil)
      allow(claude).to receive(:run_agent).and_return(success_result)
    end

    it 'posts start and completion comments for final verify' do
      allow(Open3).to receive(:capture3)
        .with('bundle', 'exec', 'rspec', chdir: '/project')
        .and_return(['', '', instance_double(Process::Status, success?: true)])

      executor_with_issues.run_pipeline(42, logger: logger, claude: claude)

      expect(issues_fetcher).to have_received(:comment)
        .with(42, /\u{1F504} \*\*Phase: final-verify\*\*/)
      expect(issues_fetcher).to have_received(:comment)
        .with(42, /\u{2705} \*\*Phase: final-verify\*\* completed/)
    end

    it 'posts failure comment when final verify fails' do
      allow(Open3).to receive(:capture3)
        .with('bundle', 'exec', 'rspec', chdir: '/project')
        .and_return(['FAIL', '', instance_double(Process::Status, success?: false)])

      executor_with_issues.run_pipeline(42, logger: logger, claude: claude)

      expect(issues_fetcher).to have_received(:comment)
        .with(42, /\u{274C} \*\*Phase: final-verify\*\* failed/)
    end
  end

  describe 'pipeline start comment' do
    let(:issues_fetcher) { instance_double(Ocak::IssueFetcher) }
    let(:executor_with_issues) { described_class.new(config: config, issues: issues_fetcher) }

    before do
      allow(issues_fetcher).to receive(:comment)
      allow(claude).to receive(:run_agent).and_return(success_result)
    end

    it 'posts start comment with complexity and step count' do
      executor_with_issues.run_pipeline(42, logger: logger, claude: claude, complexity: 'simple')

      expect(issues_fetcher).to have_received(:comment)
        .with(42, /\u{1F680} \*\*Pipeline started\*\*.*complexity: `simple`.*steps: 3/)
    end

    it 'counts conditional steps that may be skipped' do
      steps = [
        { 'agent' => 'implementer', 'role' => 'implement' },
        { 'agent' => 'reviewer', 'role' => 'review' },
        { 'agent' => 'implementer', 'role' => 'fix', 'condition' => 'has_findings' },
        { 'agent' => 'verifier', 'role' => 'verify', 'condition' => 'had_fixes' }
      ]
      allow(config).to receive(:steps).and_return(steps)

      executor_with_issues.run_pipeline(42, logger: logger, claude: claude)

      expect(issues_fetcher).to have_received(:comment)
        .with(42, /steps: 4 \(2 may be skipped\)/)
    end
  end

  describe 'skip reason comments' do
    let(:issues_fetcher) { instance_double(Ocak::IssueFetcher) }
    let(:executor_with_issues) { described_class.new(config: config, issues: issues_fetcher) }

    before do
      allow(issues_fetcher).to receive(:comment)
      allow(claude).to receive(:run_agent).and_return(success_result)
    end

    it 'posts skip comment for has_findings condition' do
      executor_with_issues.run_pipeline(42, logger: logger, claude: claude)

      expect(issues_fetcher).to have_received(:comment)
        .with(42, /\u{23ED}.*\*\*Skipping fix\*\*.*no blocking findings from review/)
    end

    it 'posts skip comment for had_fixes condition' do
      steps = [
        { 'agent' => 'implementer', 'role' => 'implement' },
        { 'agent' => 'verifier', 'role' => 'verify', 'condition' => 'had_fixes' }
      ]
      allow(config).to receive(:steps).and_return(steps)

      executor_with_issues.run_pipeline(42, logger: logger, claude: claude)

      expect(issues_fetcher).to have_received(:comment)
        .with(42, /\u{23ED}.*\*\*Skipping verify\*\*.*no fixes were made/)
    end

    it 'posts skip comment for manual review mode' do
      steps = [
        { 'agent' => 'implementer', 'role' => 'implement' },
        { 'agent' => 'merger', 'role' => 'merge' }
      ]
      allow(config).to receive(:steps).and_return(steps)
      allow(config).to receive(:manual_review).and_return(true)

      executor_with_issues.run_pipeline(42, logger: logger, claude: claude)

      expect(issues_fetcher).to have_received(:comment)
        .with(42, /\u{23ED}.*\*\*Skipping merge\*\*.*manual review mode/)
    end

    it 'posts skip comment for fast-track issue' do
      steps = [
        { 'agent' => 'implementer', 'role' => 'implement' },
        { 'agent' => 'auditor', 'role' => 'audit', 'complexity' => 'full' }
      ]
      allow(config).to receive(:steps).and_return(steps)

      executor_with_issues.run_pipeline(42, logger: logger, claude: claude, complexity: 'simple')

      expect(issues_fetcher).to have_received(:comment)
        .with(42, /\u{23ED}.*\*\*Skipping audit\*\*.*fast-track issue \(simple complexity\)/)
    end
  end

  describe 'retry comment' do
    let(:issues_fetcher) { instance_double(Ocak::IssueFetcher) }
    let(:executor_with_issues) { described_class.new(config: config, issues: issues_fetcher) }

    before do
      allow(issues_fetcher).to receive(:comment)
      allow(config).to receive(:test_command).and_return('bundle exec rspec')
      allow(config).to receive(:lint_check_command).and_return(nil)
      allow(claude).to receive(:run_agent).and_return(success_result)
    end

    it 'posts retry warning when final verification fails' do
      allow(Open3).to receive(:capture3)
        .with('bundle', 'exec', 'rspec', chdir: '/project')
        .and_return(['FAIL', '', instance_double(Process::Status, success?: false)])

      executor_with_issues.run_pipeline(42, logger: logger, claude: claude)

      expect(issues_fetcher).to have_received(:comment)
        .with(42, /\u{26A0}.*\*\*Final verification failed\*\*.*attempting auto-fix/)
    end

    it 'does not post retry warning when final verification passes' do
      allow(Open3).to receive(:capture3)
        .with('bundle', 'exec', 'rspec', chdir: '/project')
        .and_return(['', '', instance_double(Process::Status, success?: true)])

      executor_with_issues.run_pipeline(42, logger: logger, claude: claude)

      expect(issues_fetcher).not_to have_received(:comment)
        .with(42, /Final verification failed/)
    end
  end

  describe 'pipeline summary comment' do
    let(:issues_fetcher) { instance_double(Ocak::IssueFetcher) }
    let(:executor_with_issues) { described_class.new(config: config, issues: issues_fetcher) }
    let(:result_with_cost) do
      Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Done', cost_usd: 0.10, duration_ms: 30_000)
    end

    before do
      allow(issues_fetcher).to receive(:comment)
    end

    it 'posts success summary with steps run, skipped, cost, and duration' do
      allow(claude).to receive(:run_agent).and_return(result_with_cost)

      executor_with_issues.run_pipeline(42, logger: logger, claude: claude)

      expect(issues_fetcher).to have_received(:comment)
        .with(42, %r{\u{2705} \*\*Pipeline complete\*\*.*2/3 steps run.*1 skipped.*\$0\.20 total})
    end

    it 'posts failure summary with phase and steps completed' do
      allow(claude).to receive(:run_agent).with('implementer', anything, chdir: anything)
                                          .and_return(Ocak::ClaudeRunner::AgentResult.new(
                                                        success: false, output: 'Error', cost_usd: 0.05
                                                      ))

      executor_with_issues.run_pipeline(42, logger: logger, claude: claude)

      expect(issues_fetcher).to have_received(:comment)
        .with(42, %r{\u{274C} \*\*Pipeline failed\*\* at phase: implement.*1/3 steps completed.*\$0\.05 total})
    end

    it 'does not crash with nil issues' do
      allow(claude).to receive(:run_agent).and_return(success_result)

      result = executor.run_pipeline(42, logger: logger, claude: claude)

      expect(result[:success]).to be true
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

  describe 'shutdown_check' do
    it 'stops pipeline when shutdown_check returns true between steps' do
      shutdown = false
      executor_with_shutdown = described_class.new(config: config, shutdown_check: -> { shutdown })

      call_count = 0
      allow(claude).to receive(:run_agent) do |_agent, _prompt, **_opts|
        call_count += 1
        shutdown = true if call_count == 1
        success_result
      end

      result = executor_with_shutdown.run_pipeline(42, logger: logger, claude: claude)

      expect(result[:success]).to be false
      expect(result[:interrupted]).to be true
      expect(call_count).to eq(1)
    end

    it 'preserves pipeline state when interrupted' do
      executor_with_shutdown = described_class.new(config: config, shutdown_check: -> { true })

      result = executor_with_shutdown.run_pipeline(42, logger: logger, claude: claude)

      expect(result[:interrupted]).to be true
      expect(pipeline_state).not_to have_received(:delete)
    end

    it 'runs all steps when shutdown_check returns false' do
      executor_with_shutdown = described_class.new(config: config, shutdown_check: -> { false })
      allow(claude).to receive(:run_agent).and_return(success_result)

      result = executor_with_shutdown.run_pipeline(42, logger: logger, claude: claude)

      expect(result[:success]).to be true
    end

    it 'works without shutdown_check (nil)' do
      allow(claude).to receive(:run_agent).and_return(success_result)

      result = executor.run_pipeline(42, logger: logger, claude: claude)

      expect(result[:success]).to be true
    end
  end
end
