# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'ocak/state_management'
require 'ocak/run_report'

RSpec.describe Ocak::StateManagement do
  let(:test_class) do
    Class.new do
      include Ocak::StateManagement

      public :accumulate_state, :save_step_progress, :write_step_output,
             :check_step_failure, :check_cost_budget, :record_step_result,
             :update_pipeline_state, :log_cost_summary, :save_report, :sync

      def initialize(config:, logger:, pipeline_state:)
        @config = config
        @logger = logger
        @pipeline_state_obj = pipeline_state
      end

      def pipeline_state = @pipeline_state_obj
      def current_branch(_chdir, **) = 'main'
      def post_step_completion_comment(_issue_number, _role, _result, **); end
    end
  end

  let(:tmp_dir) { Dir.mktmpdir }
  after { FileUtils.rm_rf(tmp_dir) }

  let(:config) do
    instance_double(Ocak::Config, project_dir: tmp_dir, cost_budget: nil)
  end
  let(:logger) { instance_double(Ocak::PipelineLogger, info: nil, warn: nil, error: nil, debug: nil) }
  let(:pipeline_state_dbl) { instance_double(Ocak::PipelineState, save: nil) }
  let(:run_report) { instance_double(Ocak::RunReport, record_step: nil, finish: nil, save: nil) }

  subject(:instance) { test_class.new(config: config, logger: logger, pipeline_state: pipeline_state_dbl) }

  let(:success_result) { Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Done', cost_usd: 0.05) }
  let(:failure_result) { Ocak::ClaudeRunner::AgentResult.new(success: false, output: 'Error', cost_usd: 0.02) }

  def make_state(overrides = {})
    { completed_steps: [], steps_run: 0, steps_skipped: 0, total_cost: 0.0,
      step_results: {}, last_review_output: nil, had_fixes: false,
      audit_blocked: false, audit_output: nil, complexity: 'full',
      interrupted: false, report: run_report }.merge(overrides)
  end

  def make_ctx(overrides = {})
    state = overrides.delete(:state) || make_state
    Ocak::StateManagement::StepContext.new(
      overrides.fetch(:issue_number, 42),
      overrides.fetch(:idx, 0),
      overrides.fetch(:role, 'implement'),
      overrides.fetch(:result, success_result),
      state,
      overrides.fetch(:logger, logger),
      overrides.fetch(:chdir, '/project')
    )
  end

  describe '#accumulate_state' do
    it 'increments steps_run' do
      ctx = make_ctx
      instance.accumulate_state(ctx)
      expect(ctx.state[:steps_run]).to eq(1)
    end

    it 'adds result cost to total_cost' do
      ctx = make_ctx(result: success_result)
      instance.accumulate_state(ctx)
      expect(ctx.state[:total_cost]).to be_within(0.001).of(0.05)
    end

    it 'adds idx to completed_steps' do
      ctx = make_ctx(idx: 3)
      instance.accumulate_state(ctx)
      expect(ctx.state[:completed_steps]).to include(3)
    end

    it 'stores result in step_results keyed by role' do
      ctx = make_ctx(role: 'review', result: success_result)
      instance.accumulate_state(ctx)
      expect(ctx.state[:step_results]['review']).to eq(success_result)
    end
  end

  describe '#update_pipeline_state' do
    it 'sets last_review_output for review role' do
      state = make_state
      result = Ocak::ClaudeRunner::AgentResult.new(success: true, output: '🔴 finding')
      instance.update_pipeline_state('review', result, state)
      expect(state[:last_review_output]).to eq('🔴 finding')
    end

    it 'sets last_review_output for verify role' do
      state = make_state
      result = Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'output')
      instance.update_pipeline_state('verify', result, state)
      expect(state[:last_review_output]).to eq('output')
    end

    it 'sets audit_output and audit_blocked when audit output contains 🔴' do
      state = make_state
      result = Ocak::ClaudeRunner::AgentResult.new(success: true, output: '🔴 security issue')
      instance.update_pipeline_state('audit', result, state)
      expect(state[:audit_blocked]).to be true
      expect(state[:audit_output]).to eq('🔴 security issue')
    end

    it 'sets audit_blocked when audit result fails' do
      state = make_state
      result = Ocak::ClaudeRunner::AgentResult.new(success: false, output: 'error')
      instance.update_pipeline_state('audit', result, state)
      expect(state[:audit_blocked]).to be true
    end

    it 'does not set audit_blocked when audit passes with no findings' do
      state = make_state
      result = Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'all clear')
      instance.update_pipeline_state('audit', result, state)
      expect(state[:audit_blocked]).to be false
    end

    it 'sets had_fixes for fix role' do
      state = make_state
      result = Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'fixed')
      instance.update_pipeline_state('fix', result, state)
      expect(state[:had_fixes]).to be true
    end

    it 'clears last_review_output for fix role' do
      state = make_state(last_review_output: 'some output')
      result = Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'fixed')
      instance.update_pipeline_state('fix', result, state)
      expect(state[:last_review_output]).to be_nil
    end

    it 'clears last_review_output for implement role' do
      state = make_state(last_review_output: 'some output')
      result = Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'done')
      instance.update_pipeline_state('implement', result, state)
      expect(state[:last_review_output]).to be_nil
    end
  end

  describe '#save_step_progress' do
    it 'saves pipeline state with completed steps, path, and branch' do
      ctx = make_ctx(idx: 1, chdir: '/worktree')
      ctx.state[:completed_steps] << 1
      instance.save_step_progress(ctx)
      expect(pipeline_state_dbl).to have_received(:save)
        .with(42, completed_steps: [1], worktree_path: '/worktree', branch: 'main')
    end
  end

  describe '#write_step_output' do
    it 'writes output to the correct file path' do
      instance.write_step_output(42, 0, 'implement', 'some output')
      path = File.join(tmp_dir, '.ocak', 'logs', 'issue-42', 'step-0-implement.md')
      expect(File.read(path)).to eq('some output')
    end

    it 'does nothing when output is empty string' do
      instance.write_step_output(42, 0, 'implement', '')
      dir = File.join(tmp_dir, '.ocak', 'logs', 'issue-42')
      expect(Dir.exist?(dir)).to be false
    end

    it 'does nothing when output is nil' do
      expect { instance.write_step_output(42, 0, 'implement', nil) }.not_to raise_error
    end

    it 'skips write when issue_number is not all digits' do
      instance.write_step_output('../../etc', 0, 'implement', 'output')
      dir = File.join(tmp_dir, '.ocak', 'logs', 'issue-../../etc')
      expect(Dir.exist?(dir)).to be false
    end

    it 'sanitizes agent name by removing non-alphanumeric characters' do
      instance.write_step_output(42, 0, 'sec/../bad', 'output')
      path = File.join(tmp_dir, '.ocak', 'logs', 'issue-42', 'step-0-secbad.md')
      expect(File.exist?(path)).to be true
    end

    it 'logs debug when write fails' do
      allow(FileUtils).to receive(:mkdir_p).and_raise(StandardError, 'permission denied')
      instance.write_step_output(42, 0, 'implement', 'output')
      expect(logger).to have_received(:debug).with(/Step output write failed/)
    end
  end

  describe '#check_step_failure' do
    it 'returns nil when step succeeds' do
      ctx = make_ctx(role: 'implement', result: success_result)
      expect(instance.check_step_failure(ctx)).to be_nil
    end

    it 'returns failure hash when implement step fails' do
      ctx = make_ctx(role: 'implement', result: failure_result)
      result = instance.check_step_failure(ctx)
      expect(result).to eq({ success: false, phase: 'implement', output: 'Error' })
    end

    it 'returns failure hash when merge step fails' do
      ctx = make_ctx(role: 'merge', result: failure_result)
      result = instance.check_step_failure(ctx)
      expect(result).to eq({ success: false, phase: 'merge', output: 'Error' })
    end

    it 'returns nil for non-critical step failure (review)' do
      ctx = make_ctx(role: 'review', result: failure_result)
      expect(instance.check_step_failure(ctx)).to be_nil
    end

    it 'logs error when critical step fails' do
      ctx = make_ctx(role: 'implement', result: failure_result)
      instance.check_step_failure(ctx)
      expect(logger).to have_received(:error).with('implement failed')
    end
  end

  describe '#check_cost_budget' do
    it 'returns nil when no budget is configured' do
      state = make_state(total_cost: 100.0)
      expect(instance.check_cost_budget(state, logger)).to be_nil
    end

    it 'returns nil when cost is within budget' do
      allow(config).to receive(:cost_budget).and_return(10.0)
      state = make_state(total_cost: 5.0)
      expect(instance.check_cost_budget(state, logger)).to be_nil
    end

    it 'returns failure hash when cost exceeds budget' do
      allow(config).to receive(:cost_budget).and_return(1.0)
      state = make_state(total_cost: 2.5)
      result = instance.check_cost_budget(state, logger)
      expect(result).to include(success: false, phase: 'budget')
      expect(result[:output]).to include('$2.50')
    end

    it 'logs error when cost exceeds budget' do
      allow(config).to receive(:cost_budget).and_return(1.0)
      state = make_state(total_cost: 2.5)
      instance.check_cost_budget(state, logger)
      expect(logger).to have_received(:error).with(/Cost budget exceeded/)
    end
  end

  describe '#log_cost_summary' do
    it 'does nothing when cost is zero' do
      instance.log_cost_summary(0.0, logger)
      expect(logger).not_to have_received(:info)
    end

    it 'logs cost when non-zero' do
      instance.log_cost_summary(0.1234, logger)
      expect(logger).to have_received(:info).with(/Pipeline cost: \$0\.1234/)
    end

    it 'includes budget info when configured' do
      allow(config).to receive(:cost_budget).and_return(5.0)
      instance.log_cost_summary(1.5, logger)
      expect(logger).to have_received(:info).with(/\$5\.00 budget/)
    end
  end

  describe '#save_report' do
    it 'calls finish and save on the report' do
      instance.save_report(run_report, 42, success: true)
      expect(run_report).to have_received(:finish).with(success: true, failed_phase: nil)
      expect(run_report).to have_received(:save).with(42, project_dir: tmp_dir)
    end

    it 'passes failed_phase when provided' do
      instance.save_report(run_report, 42, success: false, failed_phase: 'implement')
      expect(run_report).to have_received(:finish).with(success: false, failed_phase: 'implement')
    end

    it 'swallows StandardError and logs debug' do
      allow(run_report).to receive(:finish).and_raise(StandardError, 'disk full')
      expect { instance.save_report(run_report, 42, success: true) }.not_to raise_error
      expect(logger).to have_received(:debug).with(/Report save failed/)
    end
  end

  describe '#sync' do
    it 'yields without mutex when nil' do
      called = false
      instance.sync(nil) { called = true }
      expect(called).to be true
    end

    it 'yields within mutex when provided' do
      mutex = Mutex.new
      called = false
      instance.sync(mutex) { called = true }
      expect(called).to be true
    end

    it 'returns the block value' do
      result = instance.sync(nil) { 42 }
      expect(result).to eq(42)
    end
  end
end
