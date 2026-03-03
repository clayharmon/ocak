# frozen_string_literal: true

require 'spec_helper'
require 'ocak/parallel_execution'

RSpec.describe Ocak::ParallelExecution do
  let(:logger) { instance_double(Ocak::PipelineLogger, info: nil, warn: nil, error: nil) }

  let(:host) do
    klass = Class.new do
      include Ocak::ParallelExecution

      def symbolize(step)
        step.transform_keys(&:to_sym)
      end

      def run_single_step(*); end
    end
    klass.new
  end

  describe '#run_parallel_group' do
    let(:state) { { last_review_output: nil } }
    let(:chdir) { '/project' }
    let(:claude) { instance_double(Ocak::ClaudeRunner) }

    context 'when a thread raises StandardError' do
      it 'returns a failure hash instead of nil' do
        step = { agent: 'security-reviewer', role: 'security-review', parallel: true }
        group = [[step, 0]]

        allow(host).to receive(:run_single_step).and_raise(RuntimeError, 'something went wrong')

        result = host.run_parallel_group(group, 42, state, logger: logger, claude: claude, chdir: chdir)

        expect(result).to be_a(Hash)
        expect(result[:success]).to be false
      end

      it 'includes the phase (step role) in the failure hash' do
        step = { agent: 'security-reviewer', role: 'security-review', parallel: true }
        group = [[step, 0]]

        allow(host).to receive(:run_single_step).and_raise(RuntimeError, 'boom')

        result = host.run_parallel_group(group, 42, state, logger: logger, claude: claude, chdir: chdir)

        expect(result[:phase]).to eq('security-review')
      end

      it 'includes the error message in the output field' do
        step = { agent: 'security-reviewer', role: 'security-review', parallel: true }
        group = [[step, 0]]

        allow(host).to receive(:run_single_step).and_raise(RuntimeError, 'connection refused')

        result = host.run_parallel_group(group, 42, state, logger: logger, claude: claude, chdir: chdir)

        expect(result[:output]).to eq('Thread error: connection refused')
      end

      it 'logs the error to the logger' do
        step = { agent: 'security-reviewer', role: 'security-review', parallel: true }
        group = [[step, 0]]

        allow(host).to receive(:run_single_step).and_raise(RuntimeError, 'timeout')

        host.run_parallel_group(group, 42, state, logger: logger, claude: claude, chdir: chdir)

        expect(logger).to have_received(:error).with(/security-review thread failed: timeout/)
      end
    end

    context 'when all threads succeed' do
      it 'returns nil when no failures' do
        step = { agent: 'reviewer', role: 'review', parallel: true }
        group = [[step, 0]]
        success_result = Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'All good')

        allow(host).to receive(:run_single_step).and_return(success_result)

        result = host.run_parallel_group(group, 42, state, logger: logger, claude: claude, chdir: chdir)

        expect(result).to be_nil
      end
    end

    context 'when one thread fails and another succeeds' do
      it 'returns the failure hash' do
        failing_step = { agent: 'security-reviewer', role: 'security-review', parallel: true }
        passing_step = { agent: 'reviewer', role: 'review', parallel: true }
        group = [[failing_step, 0], [passing_step, 1]]
        success_result = Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Done')

        allow(host).to receive(:run_single_step) do |step, *|
          raise 'failed' if step[:role] == 'security-review'

          success_result
        end

        result = host.run_parallel_group(group, 42, state, logger: logger, claude: claude, chdir: chdir)

        expect(result).to be_a(Hash)
        expect(result[:success]).to be false
        expect(result[:phase]).to eq('security-review')
      end
    end
  end
end
