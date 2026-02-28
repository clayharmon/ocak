# frozen_string_literal: true

require 'spec_helper'
require 'ocak/step_comments'

RSpec.describe Ocak::StepComments do
  let(:config) do
    instance_double(Ocak::Config,
                    steps: [
                      { 'agent' => 'implementer', 'role' => 'implement' },
                      { 'agent' => 'reviewer', 'role' => 'review' },
                      { 'agent' => 'implementer', 'role' => 'fix', 'condition' => 'has_findings' }
                    ],
                    manual_review: false,
                    audit_mode: false)
  end

  let(:issues_fetcher) { instance_double(Ocak::IssueFetcher) }

  let(:host) do
    klass = Class.new do
      include Ocak::StepComments

      def initialize(config, issues)
        @config = config
        @issues = issues
      end

      # Expose private methods for testing
      public :post_step_comment, :post_step_completion_comment,
             :post_pipeline_start_comment, :post_pipeline_summary_comment,
             :conditional_step_count

      def symbolize(hash)
        return hash unless hash.is_a?(Hash)

        hash.transform_keys(&:to_sym)
      end
    end
    klass.new(config, issues_fetcher)
  end

  before do
    allow(issues_fetcher).to receive(:comment)
  end

  describe '#post_step_comment' do
    it 'delegates to issues fetcher' do
      host.post_step_comment(42, 'test body')

      expect(issues_fetcher).to have_received(:comment).with(42, 'test body')
    end

    it 'does not crash when comment posting fails' do
      allow(issues_fetcher).to receive(:comment).and_raise(StandardError, 'network error')

      expect { host.post_step_comment(42, 'test') }.not_to raise_error
    end

    it 'works when issues is nil' do
      host_no_issues = Class.new do
        include Ocak::StepComments

        public :post_step_comment

        def initialize
          @issues = nil
        end
      end.new

      expect { host_no_issues.post_step_comment(42, 'test') }.not_to raise_error
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
      host.post_step_completion_comment(42, 'implement', success_result)

      expect(issues_fetcher).to have_received(:comment)
        .with(42, /\u{2705} \*\*Phase: implement\*\* completed.*45s.*\$0\.012/)
    end

    it 'posts failure comment with duration and cost' do
      host.post_step_completion_comment(42, 'implement', failure_result)

      expect(issues_fetcher).to have_received(:comment)
        .with(42, /\u{274C} \*\*Phase: implement\*\* failed.*120s.*\$0\.034/)
    end
  end

  describe '#post_pipeline_start_comment' do
    it 'includes complexity and step count' do
      state = { complexity: 'full' }

      host.post_pipeline_start_comment(42, state)

      expect(issues_fetcher).to have_received(:comment)
        .with(42, /\u{1F680} \*\*Pipeline started\*\*.*complexity: `full`.*steps: 3/)
    end

    it 'counts conditional steps that may be skipped' do
      state = { complexity: 'full' }

      host.post_pipeline_start_comment(42, state)

      expect(issues_fetcher).to have_received(:comment)
        .with(42, /1 may be skipped/)
    end
  end

  describe '#post_pipeline_summary_comment' do
    it 'posts success summary with steps, cost, and duration' do
      state = { total_cost: 0.20, steps_run: 2, steps_skipped: 1 }

      host.post_pipeline_summary_comment(42, state, 60, success: true)

      expect(issues_fetcher).to have_received(:comment)
        .with(42, %r{\u{2705} \*\*Pipeline complete\*\*.*2/3 steps run.*1 skipped.*\$0\.20 total.*60s})
    end

    it 'posts failure summary with phase and steps completed' do
      state = { total_cost: 0.05, steps_run: 1, steps_skipped: 0 }

      host.post_pipeline_summary_comment(42, state, 30, success: false, failed_phase: 'implement')

      expect(issues_fetcher).to have_received(:comment)
        .with(42, %r{\u{274C} \*\*Pipeline failed\*\* at phase: implement.*1/3 steps completed.*\$0\.05 total})
    end
  end

  describe '#conditional_step_count' do
    it 'counts steps with conditions' do
      state = { complexity: 'full' }

      expect(host.conditional_step_count(state)).to eq(1)
    end

    it 'counts complexity-skippable steps for simple issues' do
      steps = [
        { 'agent' => 'implementer', 'role' => 'implement' },
        { 'agent' => 'documenter', 'role' => 'document', 'complexity' => 'full' }
      ]
      allow(config).to receive(:steps).and_return(steps)

      expect(host.conditional_step_count({ complexity: 'simple' })).to eq(1)
    end

    it 'counts manual_review merge skip' do
      allow(config).to receive(:manual_review).and_return(true)
      steps = [
        { 'agent' => 'implementer', 'role' => 'implement' },
        { 'agent' => 'merger', 'role' => 'merge' }
      ]
      allow(config).to receive(:steps).and_return(steps)

      expect(host.conditional_step_count({ complexity: 'full' })).to eq(1)
    end

    it 'counts audit_mode merge skip' do
      allow(config).to receive(:audit_mode).and_return(true)
      steps = [
        { 'agent' => 'implementer', 'role' => 'implement' },
        { 'agent' => 'merger', 'role' => 'merge' }
      ]
      allow(config).to receive(:steps).and_return(steps)

      expect(host.conditional_step_count({ complexity: 'full' })).to eq(1)
    end
  end
end
