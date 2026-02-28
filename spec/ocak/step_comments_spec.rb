# frozen_string_literal: true

require 'spec_helper'
require 'ocak/step_comments'
require 'ocak/claude_runner'

RSpec.describe Ocak::StepComments do
  let(:test_class) do
    Class.new do
      include Ocak::StepComments

      attr_accessor :issues

      def initialize(issues:)
        @issues = issues
      end
    end
  end

  let(:issues) { instance_double(Ocak::IssueFetcher, comment: nil) }
  subject(:instance) { test_class.new(issues: issues) }

  describe '#post_step_comment' do
    it 'posts a comment via @issues' do
      instance.post_step_comment(42, 'hello')

      expect(issues).to have_received(:comment).with(42, 'hello')
    end

    it 'does not crash when @issues is nil' do
      instance.issues = nil

      expect { instance.post_step_comment(42, 'hello') }.not_to raise_error
    end

    it 'swallows StandardError from comment posting' do
      allow(issues).to receive(:comment).and_raise(StandardError, 'network error')

      expect { instance.post_step_comment(42, 'hello') }.not_to raise_error
    end

    it 'returns nil when comment posting fails' do
      allow(issues).to receive(:comment).and_raise(StandardError, 'network error')

      expect(instance.post_step_comment(42, 'hello')).to be_nil
    end

    it 'uses explicit issues: override instead of @issues' do
      override = instance_double(Ocak::IssueFetcher, comment: nil)

      instance.post_step_comment(42, 'hello', issues: override)

      expect(override).to have_received(:comment).with(42, 'hello')
      expect(issues).not_to have_received(:comment)
    end
  end

  describe '#post_step_completion_comment' do
    let(:success_result) do
      Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Done', cost_usd: 0.012, duration_ms: 45_000)
    end

    let(:failure_result) do
      Ocak::ClaudeRunner::AgentResult.new(success: false, output: 'Error', cost_usd: 0.034, duration_ms: 120_000)
    end

    it 'posts success comment with duration and cost' do
      instance.post_step_completion_comment(42, 'implement', success_result)

      expect(issues).to have_received(:comment)
        .with(42, "\u{2705} **Phase: implement** completed \u2014 45s | $0.012")
    end

    it 'posts failure comment with duration and cost' do
      instance.post_step_completion_comment(42, 'review', failure_result)

      expect(issues).to have_received(:comment)
        .with(42, "\u{274C} **Phase: review** failed \u2014 120s | $0.034")
    end

    it 'uses explicit issues: override instead of @issues' do
      override = instance_double(Ocak::IssueFetcher, comment: nil)

      instance.post_step_completion_comment(42, 'implement', success_result, issues: override)

      expect(override).to have_received(:comment)
        .with(42, "\u{2705} **Phase: implement** completed \u2014 45s | $0.012")
      expect(issues).not_to have_received(:comment)
    end

    it 'handles nil cost_usd and duration_ms' do
      result = Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Done')

      instance.post_step_completion_comment(42, 'implement', result)

      expect(issues).to have_received(:comment)
        .with(42, "\u{2705} **Phase: implement** completed \u2014 0s | $0.000")
    end
  end
end
