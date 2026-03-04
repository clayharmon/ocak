# frozen_string_literal: true

require 'spec_helper'
require 'ocak/issue_state_machine'

RSpec.describe Ocak::IssueStateMachine do
  let(:config) do
    instance_double(Ocak::Config,
                    label_ready: 'auto-ready',
                    label_in_progress: 'auto-doing',
                    label_completed: 'completed',
                    label_failed: 'pipeline-failed',
                    label_awaiting_review: 'auto-pending-human')
  end
  let(:issues) { instance_double(Ocak::IssueFetcher, transition: nil) }

  subject(:state_machine) { described_class.new(config: config, issues: issues) }

  describe '#mark_in_progress' do
    it 'transitions from ready to in-progress' do
      state_machine.mark_in_progress(42)
      expect(issues).to have_received(:transition).with(42, from: 'auto-ready', to: 'auto-doing')
    end
  end

  describe '#mark_completed' do
    it 'transitions from in-progress to completed' do
      state_machine.mark_completed(42)
      expect(issues).to have_received(:transition).with(42, from: 'auto-doing', to: 'completed')
    end
  end

  describe '#mark_failed' do
    it 'transitions from in-progress to failed' do
      state_machine.mark_failed(42)
      expect(issues).to have_received(:transition).with(42, from: 'auto-doing', to: 'pipeline-failed')
    end
  end

  describe '#mark_interrupted' do
    it 'transitions from in-progress back to ready' do
      state_machine.mark_interrupted(42)
      expect(issues).to have_received(:transition).with(42, from: 'auto-doing', to: 'auto-ready')
    end
  end

  describe '#mark_for_review' do
    it 'transitions from in-progress to awaiting review' do
      state_machine.mark_for_review(42)
      expect(issues).to have_received(:transition).with(42, from: 'auto-doing', to: 'auto-pending-human')
    end
  end

  describe '#mark_resuming' do
    it 'transitions from failed to in-progress' do
      state_machine.mark_resuming(42)
      expect(issues).to have_received(:transition).with(42, from: 'pipeline-failed', to: 'auto-doing')
    end
  end

  context 'when issues is nil' do
    subject(:state_machine) { described_class.new(config: config, issues: nil) }

    it 'does not raise on mark_in_progress' do
      expect { state_machine.mark_in_progress(42) }.not_to raise_error
    end

    it 'does not raise on mark_completed' do
      expect { state_machine.mark_completed(42) }.not_to raise_error
    end

    it 'does not raise on mark_failed' do
      expect { state_machine.mark_failed(42) }.not_to raise_error
    end

    it 'does not raise on mark_interrupted' do
      expect { state_machine.mark_interrupted(42) }.not_to raise_error
    end

    it 'does not raise on mark_for_review' do
      expect { state_machine.mark_for_review(42) }.not_to raise_error
    end

    it 'does not raise on mark_resuming' do
      expect { state_machine.mark_resuming(42) }.not_to raise_error
    end
  end

  context 'when transition raises' do
    before { allow(issues).to receive(:transition).and_raise(StandardError, 'GitHub API down') }

    it 'propagates the error' do
      expect { state_machine.mark_failed(42) }.to raise_error(StandardError, 'GitHub API down')
    end
  end
end
