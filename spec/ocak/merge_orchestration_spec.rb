# frozen_string_literal: true

require 'spec_helper'
require 'ocak/merge_orchestration'

RSpec.describe Ocak::MergeOrchestration do
  let(:host_class) do
    Class.new do
      include Ocak::MergeOrchestration

      attr_reader :config

      def initialize(config:)
        @config = config
      end

      # Expose private methods for testing
      public :merge_completed_issue, :handle_single_success, :handle_single_manual_review,
             :handle_batch_manual_review, :handle_single_audit_blocked, :handle_batch_audit,
             :create_pr_with_audit, :post_audit_comment_single, :find_pr_for_branch
    end
  end

  let(:config) do
    instance_double(Ocak::Config,
                    project_dir: '/project',
                    label_in_progress: 'in-progress',
                    label_completed: 'completed',
                    label_failed: 'pipeline-failed',
                    label_awaiting_review: 'auto-pending-human',
                    manual_review: false)
  end

  let(:host) { host_class.new(config: config) }
  let(:logger) { instance_double(Ocak::PipelineLogger, info: nil, warn: nil, error: nil) }
  let(:claude) { instance_double(Ocak::ClaudeRunner) }
  let(:issues) { instance_double(Ocak::IssueFetcher) }
  let(:merger) { instance_double(Ocak::MergeManager) }
  let(:success_result) { Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Done') }

  before do
    allow(issues).to receive(:transition)
    allow(issues).to receive(:pr_comment)
  end

  describe '#merge_completed_issue' do
    let(:result) { { issue_number: 1, success: true, worktree: '/wt' } }

    it 'merges and transitions to completed on success' do
      allow(merger).to receive(:merge).and_return(true)

      host.merge_completed_issue(result, merger: merger, issues: issues, logger: logger)

      expect(merger).to have_received(:merge).with(1, '/wt')
      expect(issues).to have_received(:transition).with(1, from: 'in-progress', to: 'completed')
    end

    it 'transitions to failed when merge fails' do
      allow(merger).to receive(:merge).and_return(false)

      host.merge_completed_issue(result, merger: merger, issues: issues, logger: logger)

      expect(issues).to have_received(:transition).with(1, from: 'in-progress', to: 'pipeline-failed')
    end

    it 'delegates to handle_batch_audit when audit_blocked' do
      blocked_result = result.merge(audit_blocked: true, audit_output: 'findings')
      allow(merger).to receive(:create_pr_only).and_return(55)

      host.merge_completed_issue(blocked_result, merger: merger, issues: issues, logger: logger)

      expect(merger).to have_received(:create_pr_only)
    end

    it 'delegates to handle_batch_manual_review in manual review mode' do
      allow(config).to receive(:manual_review).and_return(true)
      allow(merger).to receive(:create_pr_only).and_return(55)

      host.merge_completed_issue(result, merger: merger, issues: issues, logger: logger)

      expect(merger).to have_received(:create_pr_only)
    end
  end

  describe '#handle_single_success' do
    it 'runs merger agent and transitions to completed' do
      allow(claude).to receive(:run_agent).and_return(success_result)

      host.handle_single_success(42, { success: true }, logger: logger, claude: claude, issues: issues)

      expect(claude).to have_received(:run_agent)
        .with('merger', /Create a PR, merge it, and close issue #42/, chdir: '/project')
      expect(issues).to have_received(:transition).with(42, from: 'in-progress', to: 'completed')
    end

    it 'delegates to manual review when enabled' do
      allow(config).to receive(:manual_review).and_return(true)
      allow(claude).to receive(:run_agent).and_return(success_result)

      host.handle_single_success(42, { success: true }, logger: logger, claude: claude, issues: issues)

      expect(claude).to have_received(:run_agent)
        .with('merger', /do NOT merge.*do NOT close/i, chdir: '/project')
      expect(issues).to have_received(:transition).with(42, from: 'in-progress', to: 'auto-pending-human')
    end

    it 'delegates to audit blocked handler when audit_blocked' do
      allow(claude).to receive(:run_agent).and_return(success_result)
      allow(Open3).to receive(:capture3)
        .with('gh', 'pr', 'view', '--json', 'number', chdir: '/project')
        .and_return(['{"number":99}', '', instance_double(Process::Status, success?: true)])

      host.handle_single_success(42, { success: true, audit_blocked: true, audit_output: 'findings' },
                                 logger: logger, claude: claude, issues: issues)

      expect(issues).to have_received(:transition).with(42, from: 'in-progress', to: 'auto-pending-human')
      expect(issues).to have_received(:pr_comment).with(99, /Audit Report/)
    end
  end

  describe '#handle_batch_manual_review' do
    let(:result) { { issue_number: 1, worktree: '/wt' } }

    it 'creates PR and transitions to awaiting review' do
      allow(merger).to receive(:create_pr_only).and_return(55)

      host.handle_batch_manual_review(result, merger: merger, issues: issues, logger: logger)

      expect(issues).to have_received(:transition).with(1, from: 'in-progress', to: 'auto-pending-human')
    end

    it 'transitions to failed when PR creation fails' do
      allow(merger).to receive(:create_pr_only).and_return(nil)

      host.handle_batch_manual_review(result, merger: merger, issues: issues, logger: logger)

      expect(issues).to have_received(:transition).with(1, from: 'in-progress', to: 'pipeline-failed')
    end
  end

  describe '#create_pr_with_audit' do
    let(:result) { { issue_number: 1, worktree: '/wt' } }

    it 'creates PR and posts audit comment' do
      allow(merger).to receive(:create_pr_only).and_return(55)

      host.create_pr_with_audit(result, 'audit findings', merger: merger, issues: issues, logger: logger)

      expect(issues).to have_received(:pr_comment).with(55, /Audit Report.*audit findings/m)
      expect(issues).to have_received(:transition).with(1, from: 'in-progress', to: 'auto-pending-human')
    end

    it 'transitions to failed when PR creation fails' do
      allow(merger).to receive(:create_pr_only).and_return(nil)

      host.create_pr_with_audit(result, 'audit findings', merger: merger, issues: issues, logger: logger)

      expect(issues).to have_received(:transition).with(1, from: 'in-progress', to: 'pipeline-failed')
    end
  end

  describe '#find_pr_for_branch' do
    it 'returns PR number from gh cli output' do
      allow(Open3).to receive(:capture3)
        .with('gh', 'pr', 'view', '--json', 'number', chdir: '/project')
        .and_return(['{"number":99}', '', instance_double(Process::Status, success?: true)])

      expect(host.find_pr_for_branch(logger: logger)).to eq(99)
    end

    it 'returns nil when gh command fails' do
      allow(Open3).to receive(:capture3)
        .with('gh', 'pr', 'view', '--json', 'number', chdir: '/project')
        .and_return(['', '', instance_double(Process::Status, success?: false)])

      expect(host.find_pr_for_branch(logger: logger)).to be_nil
    end

    it 'returns nil and logs warning on JSON parse error' do
      allow(Open3).to receive(:capture3)
        .with('gh', 'pr', 'view', '--json', 'number', chdir: '/project')
        .and_return(['not json', '', instance_double(Process::Status, success?: true)])

      expect(host.find_pr_for_branch(logger: logger)).to be_nil
      expect(logger).to have_received(:warn).with(/Failed to find PR number/)
    end
  end
end
