# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Ocak::RereadyProcessor do
  let(:config) do
    instance_double(Ocak::Config,
                    project_dir: '/project',
                    label_reready: 'auto-reready',
                    test_command: 'bundle exec rspec',
                    lint_check_command: 'bundle exec rubocop')
  end

  let(:logger) { instance_double(Ocak::PipelineLogger, info: nil, warn: nil, error: nil) }
  let(:claude) { instance_double(Ocak::ClaudeRunner) }
  let(:issues) { instance_double(Ocak::IssueFetcher) }
  let(:success_status) { instance_double(Process::Status, success?: true) }
  let(:failure_status) { instance_double(Process::Status, success?: false) }

  let(:success_result) { Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Done') }
  let(:failure_result) { Ocak::ClaudeRunner::AgentResult.new(success: false, output: 'Error') }

  subject(:processor) do
    described_class.new(config: config, logger: logger, claude: claude, issues: issues)
  end

  let(:pr) do
    {
      'number' => 10,
      'title' => 'Fix #42: Fix the bug',
      'body' => 'Closes #42',
      'headRefName' => 'auto/issue-42-abc123',
      'labels' => [{ 'name' => 'auto-reready' }]
    }
  end

  # Always stub cleanup
  before do
    allow(Open3).to receive(:capture3)
      .with('git', 'checkout', 'main', chdir: '/project')
      .and_return(['', '', success_status])
  end

  describe '#process' do
    context 'when PR body has no issue number' do
      let(:pr_no_issue) do
        { 'number' => 10, 'title' => 'Some PR', 'body' => 'No issue ref',
          'headRefName' => 'some-branch', 'labels' => [] }
      end

      before do
        allow(issues).to receive(:extract_issue_number_from_pr).and_return(nil)
      end

      it 'returns false and logs a warning' do
        expect(processor.process(pr_no_issue)).to be false
        expect(logger).to have_received(:warn).with(/could not extract issue number/)
      end
    end

    context 'when issue data cannot be fetched' do
      before do
        allow(issues).to receive(:extract_issue_number_from_pr).and_return(42)
        allow(issues).to receive(:fetch_pr_comments).and_return({ comments: [], reviews: [] })
        allow(issues).to receive(:view)
          .with(42, fields: 'title,body')
          .and_return(nil)
      end

      it 'returns false' do
        expect(processor.process(pr)).to be false
      end
    end

    context 'when branch checkout fails' do
      before do
        allow(issues).to receive(:extract_issue_number_from_pr).and_return(42)
        allow(issues).to receive(:fetch_pr_comments).and_return({ comments: [], reviews: [] })
        allow(issues).to receive(:view)
          .with(42, fields: 'title,body')
          .and_return({ 'title' => 'Fix bug', 'body' => 'desc' })

        allow(Open3).to receive(:capture3)
          .with('git', 'fetch', 'origin', 'auto/issue-42-abc123', chdir: '/project')
          .and_return(['', 'error', failure_status])
      end

      it 'returns false and logs an error' do
        expect(processor.process(pr)).to be false
        expect(logger).to have_received(:error).with(/failed to checkout branch/)
      end
    end

    context 'happy path' do
      before do
        allow(issues).to receive(:extract_issue_number_from_pr).and_return(42)
        allow(issues).to receive(:fetch_pr_comments).and_return({
                                                                  comments: [{ 'author' => { 'login' => 'user' },
                                                                               'body' => 'fix this' }],
                                                                  reviews: []
                                                                })
        allow(issues).to receive(:view)
          .with(42, fields: 'title,body')
          .and_return({ 'title' => 'Fix bug', 'body' => 'desc' })

        # Checkout
        allow(Open3).to receive(:capture3)
          .with('git', 'fetch', 'origin', 'auto/issue-42-abc123', chdir: '/project')
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'checkout', 'auto/issue-42-abc123', chdir: '/project')
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'pull', '--rebase', 'origin', 'auto/issue-42-abc123', chdir: '/project')
          .and_return(['', '', success_status])

        # Implementer runs
        allow(claude).to receive(:run_agent).and_return(success_result)

        # Verification passes
        allow(Open3).to receive(:capture3)
          .with('bundle', 'exec', 'rspec', chdir: '/project')
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('bundle', 'exec', 'rubocop', chdir: '/project')
          .and_return(['', '', success_status])

        # Push
        allow(Open3).to receive(:capture3)
          .with('git', 'add', '-A', chdir: '/project')
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'status', '--porcelain', chdir: '/project')
          .and_return(["M file.rb\n", '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'commit', '-m', 'fix: address review feedback', chdir: '/project')
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'push', '--force-with-lease', chdir: '/project')
          .and_return(['', '', success_status])

        allow(issues).to receive(:pr_transition).and_return(true)
        allow(issues).to receive(:pr_comment).and_return(true)
      end

      it 'returns true' do
        expect(processor.process(pr)).to be true
      end

      it 'removes the reready label' do
        processor.process(pr)

        expect(issues).to have_received(:pr_transition)
          .with(10, remove_label: 'auto-reready')
      end

      it 'comments that feedback was addressed' do
        processor.process(pr)

        expect(issues).to have_received(:pr_comment)
          .with(10, 'Feedback addressed. Please re-review.')
      end
    end

    context 'when implementer fails' do
      before do
        allow(issues).to receive(:extract_issue_number_from_pr).and_return(42)
        allow(issues).to receive(:fetch_pr_comments).and_return({ comments: [], reviews: [] })
        allow(issues).to receive(:view)
          .with(42, fields: 'title,body')
          .and_return({ 'title' => 'Fix bug', 'body' => 'desc' })

        # Checkout succeeds
        allow(Open3).to receive(:capture3)
          .with('git', 'fetch', 'origin', 'auto/issue-42-abc123', chdir: '/project')
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'checkout', 'auto/issue-42-abc123', chdir: '/project')
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'pull', '--rebase', 'origin', 'auto/issue-42-abc123', chdir: '/project')
          .and_return(['', '', success_status])

        # Implementer fails
        allow(claude).to receive(:run_agent).and_return(failure_result)

        allow(issues).to receive(:pr_transition).and_return(true)
        allow(issues).to receive(:pr_comment).and_return(true)
      end

      it 'returns false' do
        expect(processor.process(pr)).to be false
      end

      it 'removes the reready label and comments failure' do
        processor.process(pr)

        expect(issues).to have_received(:pr_transition)
          .with(10, remove_label: 'auto-reready')
        expect(issues).to have_received(:pr_comment)
          .with(10, 'Failed to address feedback automatically. Please check logs.')
      end
    end
  end
end
