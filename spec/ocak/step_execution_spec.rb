# frozen_string_literal: true

require 'spec_helper'
require 'ocak/step_execution'
require 'ocak/state_management'

RSpec.describe Ocak::StepExecution do
  let(:test_class) do
    Class.new do
      include Ocak::StepExecution

      public :run_single_step, :handle_already_completed, :record_skipped_step,
             :execute_step, :skip_reason

      def initialize(config:, skip_steps: [], skip_merge: false)
        @config = config
        @skip_steps = skip_steps
        @skip_merge = skip_merge
      end

      def post_step_comment(issue_number, message, **); end
      def build_step_prompt(_role, _issue_number, _review_output) = 'test prompt'
      def record_step_result(*) = nil
    end
  end

  let(:config) do
    instance_double(Ocak::Config, audit_mode: false, manual_review: false)
  end
  let(:logger) { instance_double(Ocak::PipelineLogger, info: nil, warn: nil, error: nil, debug: nil) }
  let(:claude) { instance_double(Ocak::ClaudeRunner) }
  let(:success_result) { Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Done') }
  let(:failure_result) { Ocak::ClaudeRunner::AgentResult.new(success: false, output: 'Error') }
  let(:run_report) { instance_double(Ocak::RunReport, record_step: nil) }

  let(:base_state) do
    { completed_steps: [], steps_run: 0, steps_skipped: 0, total_cost: 0.0,
      step_results: {}, last_review_output: nil, had_fixes: false,
      audit_blocked: false, complexity: 'full', report: run_report }
  end

  subject(:instance) { test_class.new(config: config) }

  describe '#handle_already_completed' do
    it 'returns false when idx is not in skip_steps' do
      expect(instance.handle_already_completed(0, 'implement', [], logger)).to be false
    end

    it 'returns true when idx is in skip_steps' do
      expect(instance.handle_already_completed(0, 'implement', [0], logger)).to be true
    end

    it 'logs info message when step is already completed' do
      instance.handle_already_completed(0, 'implement', [0], logger)
      expect(logger).to have_received(:info).with('Skipping implement (already completed)')
    end

    it 'does not log when step is not skipped' do
      instance.handle_already_completed(0, 'implement', [], logger)
      expect(logger).not_to have_received(:info)
    end
  end

  describe '#skip_reason' do
    let(:step) { { role: 'implement', agent: 'implementer' } }

    it 'returns nil when no skip condition applies' do
      expect(instance.skip_reason(step, base_state)).to be_nil
    end

    it 'returns merge skip reason when skip_merge is true' do
      host = test_class.new(config: config, skip_merge: true)
      merge_step = { role: 'merge', agent: 'merger' }
      expect(host.skip_reason(merge_step, base_state)).to eq('merge handled by MergeManager')
    end

    it 'returns audit blocking reason when audit_blocked is true' do
      allow(config).to receive(:audit_mode).and_return(true)
      merge_step = { role: 'merge', agent: 'merger' }
      state = base_state.merge(audit_blocked: true)
      expect(instance.skip_reason(merge_step, state)).to eq('audit found blocking issues')
    end

    it 'returns manual review reason when manual_review is true' do
      allow(config).to receive(:manual_review).and_return(true)
      merge_step = { role: 'merge', agent: 'merger' }
      expect(instance.skip_reason(merge_step, base_state)).to eq('manual review mode')
    end

    it 'returns complexity reason for full step on simple issue' do
      complex_step = { role: 'document', agent: 'documenter', complexity: 'full' }
      state = base_state.merge(complexity: 'simple')
      expect(instance.skip_reason(complex_step, state)).to eq('fast-track issue (simple complexity)')
    end

    it 'returns nil for full step on full complexity issue' do
      complex_step = { role: 'document', agent: 'documenter', complexity: 'full' }
      expect(instance.skip_reason(complex_step, base_state)).to be_nil
    end

    it 'returns has_findings reason when no blocking findings' do
      findings_step = { role: 'fix', agent: 'implementer', condition: 'has_findings' }
      state = base_state.merge(last_review_output: 'all good')
      expect(instance.skip_reason(findings_step, state)).to eq('no blocking findings from review')
    end

    it 'returns has_findings reason when last_review_output is nil' do
      findings_step = { role: 'fix', agent: 'implementer', condition: 'has_findings' }
      expect(instance.skip_reason(findings_step, base_state)).to eq('no blocking findings from review')
    end

    it 'does not skip has_findings step when 🔴 findings are present' do
      findings_step = { role: 'fix', agent: 'implementer', condition: 'has_findings' }
      state = base_state.merge(last_review_output: '🔴 critical finding')
      expect(instance.skip_reason(findings_step, state)).to be_nil
    end

    it 'returns had_fixes reason when no fixes were made' do
      fixes_step = { role: 'verify', agent: 'verifier', condition: 'had_fixes' }
      expect(instance.skip_reason(fixes_step, base_state)).to eq('no fixes were made')
    end

    it 'does not skip had_fixes step when fixes were made' do
      fixes_step = { role: 'verify', agent: 'verifier', condition: 'had_fixes' }
      state = base_state.merge(had_fixes: true)
      expect(instance.skip_reason(fixes_step, state)).to be_nil
    end
  end

  describe '#record_skipped_step' do
    let(:state) { base_state.dup }

    before { allow(instance).to receive(:post_step_comment) }

    it 'increments steps_skipped' do
      instance.record_skipped_step(42, state, 0, 'implementer', 'implement', 'no findings')
      expect(state[:steps_skipped]).to eq(1)
    end

    it 'posts a skip comment' do
      instance.record_skipped_step(42, state, 0, 'implementer', 'implement', 'no findings')
      expect(instance).to have_received(:post_step_comment)
        .with(42, '⏭️ **Skipping implement** — no findings')
    end

    it 'records step in report with skipped status' do
      instance.record_skipped_step(42, state, 0, 'implementer', 'implement', 'no findings')
      expect(run_report).to have_received(:record_step).with(
        index: 0, agent: 'implementer', role: 'implement', status: 'skipped', skip_reason: 'no findings'
      )
    end
  end

  describe '#execute_step' do
    let(:step) { { role: 'implement', agent: 'implementer' } }

    before do
      allow(claude).to receive(:run_agent).and_return(success_result)
      allow(instance).to receive(:post_step_comment)
    end

    it 'calls claude.run_agent with agent and prompt' do
      instance.execute_step(step, 42, nil, logger: logger, claude: claude, chdir: '/project')
      expect(claude).to have_received(:run_agent).with('implementer', 'test prompt', chdir: '/project')
    end

    it 'returns the agent result' do
      result = instance.execute_step(step, 42, nil, logger: logger, claude: claude, chdir: '/project')
      expect(result).to eq(success_result)
    end

    it 'passes model override when step has model key' do
      model_step = { role: 'implement', agent: 'implementer', model: 'sonnet' }
      instance.execute_step(model_step, 42, nil, logger: logger, claude: claude, chdir: '/project')
      expect(claude).to have_received(:run_agent)
        .with('implementer', 'test prompt', chdir: '/project', model: 'sonnet')
    end

    it 'converts underscore agent names to hyphens' do
      hyphen_step = { role: 'security', agent: 'security_reviewer' }
      instance.execute_step(hyphen_step, 42, nil, logger: logger, claude: claude, chdir: '/project')
      expect(claude).to have_received(:run_agent).with('security-reviewer', 'test prompt', chdir: '/project')
    end

    it 'posts in-progress step comment' do
      instance.execute_step(step, 42, nil, logger: logger, claude: claude, chdir: '/project')
      expect(instance).to have_received(:post_step_comment)
        .with(42, '🔄 **Phase: implement** (implementer)')
    end

    it 'logs phase info' do
      instance.execute_step(step, 42, nil, logger: logger, claude: claude, chdir: '/project')
      expect(logger).to have_received(:info).with('--- Phase: implement (implementer) ---')
    end
  end

  describe '#run_single_step' do
    let(:step) { { role: 'implement', agent: 'implementer' } }
    let(:state) { base_state.dup }

    before do
      allow(claude).to receive(:run_agent).and_return(success_result)
      allow(instance).to receive(:post_step_comment)
      allow(instance).to receive(:record_step_result)
    end

    it 'returns nil when step is already completed (in skip_steps)' do
      host = test_class.new(config: config, skip_steps: [0])
      result = host.run_single_step(step, 0, 42, state, logger: logger, claude: claude, chdir: '/project')
      expect(result).to be_nil
      expect(claude).not_to have_received(:run_agent)
    end

    it 'returns nil when step is skipped due to condition' do
      findings_step = { role: 'fix', agent: 'implementer', condition: 'has_findings' }
      result = instance.run_single_step(findings_step, 0, 42, state, logger: logger, claude: claude,
                                                                     chdir: '/project')
      expect(result).to be_nil
      expect(claude).not_to have_received(:run_agent)
    end

    it 'logs skip reason info message' do
      findings_step = { role: 'fix', agent: 'implementer', condition: 'has_findings' }
      instance.run_single_step(findings_step, 0, 42, state, logger: logger, claude: claude, chdir: '/project')
      expect(logger).to have_received(:info).with(/Skipping fix/)
    end

    it 'executes step and calls record_step_result' do
      instance.run_single_step(step, 0, 42, state, logger: logger, claude: claude, chdir: '/project')
      expect(instance).to have_received(:record_step_result)
    end

    it 'records step in report with completed status' do
      instance.run_single_step(step, 0, 42, state, logger: logger, claude: claude, chdir: '/project')
      expect(run_report).to have_received(:record_step).with(
        index: 0, agent: 'implementer', role: 'implement', status: 'completed', result: success_result
      )
    end

    it 'passes mutex to record_step_result' do
      mutex = Mutex.new
      instance.run_single_step(step, 0, 42, state, logger: logger, claude: claude, chdir: '/project',
                                                   mutex: mutex)
      expect(instance).to have_received(:record_step_result).with(anything, mutex: mutex)
    end
  end
end
