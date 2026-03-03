# frozen_string_literal: true

require 'spec_helper'
require 'ocak/parallel_execution'

RSpec.describe Ocak::ParallelExecution do
  let(:test_class) do
    Class.new do
      include Ocak::ParallelExecution

      attr_accessor :run_single_step_impl

      def initialize
        @run_single_step_impl = nil
      end

      def symbolize(hash)
        return hash unless hash.is_a?(Hash)

        hash.transform_keys(&:to_sym)
      end

      def run_single_step(step, idx, issue_number, state, logger:, claude:, chdir:, mutex: nil) # rubocop:disable Metrics/ParameterLists
        @run_single_step_impl&.call(step, idx, issue_number, state,
                                    logger: logger, claude: claude, chdir: chdir, mutex: mutex)
      end
    end
  end

  let(:logger) { instance_double(Ocak::PipelineLogger, info: nil, warn: nil, error: nil, debug: nil) }
  let(:claude) { instance_double(Ocak::ClaudeRunner) }
  let(:success_result) { Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Done') }
  let(:failure_result) { Ocak::ClaudeRunner::AgentResult.new(success: false, output: 'Error') }

  let(:base_state) do
    { completed_steps: [], steps_run: 0, total_cost: 0.0, step_results: {},
      last_review_output: nil, had_fixes: false, audit_blocked: false }
  end

  subject(:instance) { test_class.new }

  describe '#collect_parallel_group' do
    it 'collects consecutive parallel steps starting at start_idx' do
      steps = [
        { 'agent' => 'reviewer', 'role' => 'review', 'parallel' => true },
        { 'agent' => 'security-reviewer', 'role' => 'security', 'parallel' => true },
        { 'agent' => 'merger', 'role' => 'merge' }
      ]
      group = instance.collect_parallel_group(steps, 0)
      expect(group.size).to eq(2)
      expect(group.map(&:last)).to eq([0, 1])
    end

    it 'stops at first non-parallel step' do
      steps = [
        { 'agent' => 'reviewer', 'role' => 'review', 'parallel' => true },
        { 'agent' => 'merger', 'role' => 'merge' },
        { 'agent' => 'auditor', 'role' => 'audit', 'parallel' => true }
      ]
      group = instance.collect_parallel_group(steps, 0)
      expect(group.size).to eq(1)
    end

    it 'returns empty array when first step is not parallel' do
      steps = [{ 'agent' => 'implementer', 'role' => 'implement' }]
      group = instance.collect_parallel_group(steps, 0)
      expect(group).to be_empty
    end

    it 'collects from non-zero start_idx' do
      steps = [
        { 'agent' => 'implementer', 'role' => 'implement' },
        { 'agent' => 'reviewer', 'role' => 'review', 'parallel' => true },
        { 'agent' => 'security-reviewer', 'role' => 'security', 'parallel' => true }
      ]
      group = instance.collect_parallel_group(steps, 1)
      expect(group.size).to eq(2)
      expect(group.map(&:last)).to eq([1, 2])
    end

    it 'returns empty array when start_idx is beyond steps size' do
      steps = [{ 'agent' => 'implementer', 'role' => 'implement' }]
      group = instance.collect_parallel_group(steps, 5)
      expect(group).to be_empty
    end

    it 'symbolizes step hashes when collecting' do
      steps = [{ 'agent' => 'reviewer', 'role' => 'review', 'parallel' => true }]
      group = instance.collect_parallel_group(steps, 0)
      step_hash = group.first.first
      expect(step_hash[:parallel]).to be true
    end
  end

  describe '#run_parallel_group' do
    let(:step_a) { { agent: 'reviewer', role: 'review', parallel: true } }
    let(:step_b) { { agent: 'security-reviewer', role: 'security', parallel: true } }
    let(:group) { [[step_a, 0], [step_b, 1]] }

    context 'when all threads succeed' do
      it 'runs all steps and returns nil when all succeed' do
        instance.run_single_step_impl = ->(*_args, **_kwargs) {}
        result = instance.run_parallel_group(group, 42, base_state, logger: logger, claude: claude,
                                                                    chdir: '/project')
        expect(result).to be_nil
      end

      it 'runs steps in parallel (both steps called)' do
        called_roles = []
        mutex = Mutex.new
        instance.run_single_step_impl = lambda do |step, *_args, **_kwargs|
          mutex.synchronize { called_roles << step[:role] }
          nil
        end

        instance.run_parallel_group(group, 42, base_state, logger: logger, claude: claude, chdir: '/project')
        expect(called_roles).to contain_exactly('review', 'security')
      end
    end

    context 'when a step returns a failure result' do
      it 'returns first failure result' do
        failure_hash = { success: false, phase: 'security', output: 'Error' }
        instance.run_single_step_impl = lambda do |step, *_args, **_kwargs|
          step[:role] == 'security' ? failure_hash : nil
        end

        result = instance.run_parallel_group(group, 42, base_state, logger: logger, claude: claude,
                                                                    chdir: '/project')
        expect(result).to eq(failure_hash)
      end
    end

    context 'when a thread raises StandardError' do
      it 'returns a failure hash instead of nil' do
        instance.run_single_step_impl = ->(*_args, **_kwargs) { raise 'something went wrong' }

        result = instance.run_parallel_group([[step_a, 0]], 42, base_state, logger: logger, claude: claude,
                                                                            chdir: '/project')

        expect(result).to be_a(Hash)
        expect(result[:success]).to be false
      end

      it 'includes the phase (step role) in the failure hash' do
        instance.run_single_step_impl = ->(*_args, **_kwargs) { raise 'boom' }

        result = instance.run_parallel_group([[step_a, 0]], 42, base_state, logger: logger, claude: claude,
                                                                            chdir: '/project')

        expect(result[:phase]).to eq('review')
      end

      it 'includes the error message in the output field' do
        instance.run_single_step_impl = ->(*_args, **_kwargs) { raise 'connection refused' }

        result = instance.run_parallel_group([[step_a, 0]], 42, base_state, logger: logger, claude: claude,
                                                                            chdir: '/project')

        expect(result[:output]).to eq('Thread error: connection refused')
      end

      it 'logs the error to the logger' do
        instance.run_single_step_impl = ->(*_args, **_kwargs) { raise 'timeout' }

        instance.run_parallel_group([[step_a, 0]], 42, base_state, logger: logger, claude: claude,
                                                                   chdir: '/project')

        expect(logger).to have_received(:error).with(/review thread failed: timeout/)
      end
    end

    context 'when one thread fails and another succeeds' do
      it 'returns the failure hash' do
        instance.run_single_step_impl = lambda do |step, *_args, **_kwargs|
          raise 'failed' if step[:role] == 'security'

          nil
        end

        result = instance.run_parallel_group(group, 42, base_state, logger: logger, claude: claude,
                                                                    chdir: '/project')

        expect(result).to be_a(Hash)
        expect(result[:success]).to be false
        expect(result[:phase]).to eq('security')
      end
    end

    it 'passes a shared mutex to run_single_step' do
      received_mutexes = []
      instance.run_single_step_impl = lambda do |_step, _idx, _issue_number, _state,
                                                  mutex: nil, **_|
        received_mutexes << mutex
        nil
      end

      instance.run_parallel_group(group, 42, base_state, logger: logger, claude: claude, chdir: '/project')
      expect(received_mutexes.uniq.size).to eq(1)
      expect(received_mutexes.first).to be_a(Mutex)
    end
  end
end
