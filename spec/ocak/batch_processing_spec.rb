# frozen_string_literal: true

require 'spec_helper'
require 'ocak/batch_processing'
require 'ocak/worktree_manager'

RSpec.describe Ocak::BatchProcessing do
  let(:test_class) do
    Class.new do
      include Ocak::BatchProcessing

      public :process_issues, :run_batch, :process_one_issue, :build_issue_result, :resolve_targets

      attr_accessor :shutting_down

      def initialize(config:, options: {}, executor: nil)
        @config = config
        @options = options
        @executor = executor
        @shutting_down = false
        @active_mutex = Mutex.new
        @active_issues = []
      end

      def build_claude(_logger) = nil
      def build_logger(**) = nil
      def build_merge_manager(**) = nil
      def run_pipeline(_issue_number, **_opts) = { success: true }
      def merge_completed_issue(_result, merger:, issues:, logger:); end
      def handle_interrupted_issue(_issue_number, _path, _phase, logger:, issues:); end
      def report_pipeline_failure(_issue_number, _result, issues:, config:, logger:); end
      def handle_process_error(_error, issue_number:, logger:, issues:); end
    end
  end

  let(:config) do
    instance_double(Ocak::Config,
                    max_issues_per_run: 3,
                    max_parallel: 2,
                    label_ready: 'auto-ready',
                    label_in_progress: 'in-progress',
                    label_failed: 'pipeline-failed',
                    setup_command: nil,
                    multi_repo?: false)
  end
  let(:logger) { instance_double(Ocak::PipelineLogger, info: nil, warn: nil, error: nil, debug: nil) }
  let(:issues) { instance_double(Ocak::IssueFetcher, transition: nil, comment: nil) }
  let(:executor) { double('executor') }
  let(:worktree) do
    instance_double(Ocak::WorktreeManager::Worktree, path: '/worktrees/42', branch: 'auto/issue-42',
                                                     target_repo: nil)
  end
  let(:worktrees) { instance_double(Ocak::WorktreeManager, create: worktree, remove: nil) }

  subject(:instance) { test_class.new(config: config, executor: executor) }

  let(:ready_issue) { { 'number' => 42, 'title' => 'Fix bug' } }

  describe '#process_issues' do
    let(:batch) { { 'issues' => [ready_issue] } }

    before do
      allow(executor).to receive(:plan_batches).and_return([batch])
      allow(instance).to receive(:run_batch)
    end

    it 'caps issues to max_issues_per_run' do
      many_issues = (1..5).map { |n| { 'number' => n, 'title' => "Issue #{n}" } }
      allow(executor).to receive(:plan_batches).and_return([{ 'issues' => many_issues[0...2] }])

      instance.process_issues(many_issues, logger: logger, issues: issues)

      expect(executor).to have_received(:plan_batches) do |issues_arg, **|
        expect(issues_arg.size).to be <= 3
      end
    end

    it 'logs warning when capping issues' do
      many_issues = (1..5).map { |n| { 'number' => n, 'title' => "Issue #{n}" } }
      allow(executor).to receive(:plan_batches).and_return([])

      instance.process_issues(many_issues, logger: logger, issues: issues)

      expect(logger).to have_received(:warn).with(/Capping to 3 issues/)
    end

    it 'logs batch info before running' do
      instance.process_issues([ready_issue], logger: logger, issues: issues)
      expect(logger).to have_received(:info).with(%r{Running batch 1/1})
    end

    it 'calls run_batch for each batch' do
      instance.process_issues([ready_issue], logger: logger, issues: issues)
      expect(instance).to have_received(:run_batch)
    end

    it 'logs dry run message and skips run_batch when dry_run option is set' do
      host = test_class.new(config: config, options: { dry_run: true }, executor: executor)
      allow(executor).to receive(:plan_batches).and_return([batch])
      allow(host).to receive(:run_batch)

      host.process_issues([ready_issue], logger: logger, issues: issues)

      expect(host).not_to have_received(:run_batch)
      expect(logger).to have_received(:info).with(/DRY RUN/)
    end

    context 'when multi_repo? is true' do
      let(:multi_config) do
        instance_double(Ocak::Config,
                        max_issues_per_run: 3,
                        max_parallel: 2,
                        label_ready: 'auto-ready',
                        label_in_progress: 'in-progress',
                        label_failed: 'pipeline-failed',
                        setup_command: nil,
                        multi_repo?: true)
      end

      it 'calls resolve_targets before batching' do
        host = test_class.new(config: multi_config, executor: executor)
        allow(executor).to receive(:plan_batches).and_return([{ 'issues' => [ready_issue] }])
        allow(host).to receive(:run_batch)
        allow(host).to receive(:resolve_targets).and_return([ready_issue])

        host.process_issues([ready_issue], logger: logger, issues: issues)

        expect(host).to have_received(:resolve_targets).with([ready_issue], logger: logger)
      end
    end
  end

  describe '#run_batch' do
    before do
      allow(Ocak::WorktreeManager).to receive(:new).and_return(worktrees)
      allow(instance).to receive(:process_one_issue).and_return(
        { issue_number: 42, success: true, worktree: worktree }
      )
      allow(instance).to receive(:merge_completed_issue)
      allow(instance).to receive(:build_merge_manager).and_return(nil)
    end

    it 'processes all issues and calls merge for successful ones' do
      instance.run_batch([ready_issue], logger: logger, issues: issues)
      expect(instance).to have_received(:merge_completed_issue)
    end

    it 'removes worktree for completed issues' do
      instance.run_batch([ready_issue], logger: logger, issues: issues)
      expect(worktrees).to have_received(:remove).with(worktree)
    end

    it 'skips merging when shutting_down is true' do
      instance.shutting_down = true
      instance.run_batch([ready_issue], logger: logger, issues: issues)
      expect(instance).not_to have_received(:merge_completed_issue)
    end

    it 'skips worktree removal for interrupted results' do
      allow(instance).to receive(:process_one_issue).and_return(
        { issue_number: 42, success: false, worktree: worktree, interrupted: true }
      )
      instance.run_batch([ready_issue], logger: logger, issues: issues)
      expect(worktrees).not_to have_received(:remove)
    end

    it 'logs warning when worktree removal fails' do
      allow(worktrees).to receive(:remove).and_raise(StandardError, 'locked')
      instance.run_batch([ready_issue], logger: logger, issues: issues)
      expect(logger).to have_received(:warn).with(/Failed to clean worktree/)
    end

    it 'skips worktree removal when result has no worktree' do
      allow(instance).to receive(:process_one_issue).and_return(
        { issue_number: 42, success: false, worktree: nil }
      )
      instance.run_batch([ready_issue], logger: logger, issues: issues)
      expect(worktrees).not_to have_received(:remove)
    end

    it 'raises programming error if one is present in results' do
      error = NoMethodError.new('undefined method')
      allow(instance).to receive(:process_one_issue).and_return(
        { issue_number: 42, success: false, worktree: nil, programming_error: error }
      )
      expect { instance.run_batch([ready_issue], logger: logger, issues: issues) }.to raise_error(NoMethodError)
    end

    context 'when multi_repo? is false' do
      it 'creates a shared WorktreeManager' do
        instance.run_batch([ready_issue], logger: logger, issues: issues)
        expect(Ocak::WorktreeManager).to have_received(:new).with(config: config, logger: logger)
      end
    end

    context 'when multi_repo? is true' do
      let(:multi_config) do
        instance_double(Ocak::Config,
                        max_issues_per_run: 3,
                        max_parallel: 2,
                        label_ready: 'auto-ready',
                        label_in_progress: 'in-progress',
                        label_failed: 'pipeline-failed',
                        setup_command: nil,
                        multi_repo?: true)
      end

      it 'passes worktrees: nil to process_one_issue so each thread creates its own' do
        host = test_class.new(config: multi_config, executor: executor)
        allow(host).to receive(:process_one_issue).and_return(
          { issue_number: 42, success: true, worktree: worktree }
        )
        allow(host).to receive(:merge_completed_issue)
        allow(host).to receive(:build_merge_manager).and_return(nil)
        allow(Ocak::WorktreeManager).to receive(:new).and_return(worktrees)

        host.run_batch([ready_issue], logger: logger, issues: issues)

        expect(host).to have_received(:process_one_issue).with(ready_issue, worktrees: nil, issues: issues)
      end

      it 'creates a repo-specific WorktreeManager for worktree cleanup when target_repo is set' do
        target_worktree = instance_double(
          Ocak::WorktreeManager::Worktree,
          path: '/dev/my-gem/.claude/worktrees/issue-42',
          branch: 'auto/issue-42',
          target_repo: { path: '/dev/my-gem' }
        )
        target_worktrees = instance_double(Ocak::WorktreeManager, remove: nil)
        allow(Ocak::WorktreeManager).to receive(:new)
          .with(config: multi_config, repo_dir: '/dev/my-gem', logger: logger)
          .and_return(target_worktrees)

        host = test_class.new(config: multi_config, executor: executor)
        allow(host).to receive(:process_one_issue).and_return(
          { issue_number: 42, success: true, worktree: target_worktree }
        )
        allow(host).to receive(:merge_completed_issue)
        allow(host).to receive(:build_merge_manager).and_return(nil)

        host.run_batch([ready_issue], logger: logger, issues: issues)

        expect(target_worktrees).to have_received(:remove).with(target_worktree)
      end
    end
  end

  describe '#process_one_issue' do
    let(:claude) { instance_double(Ocak::ClaudeRunner) }
    let(:success_pipeline_result) { { success: true, interrupted: false } }

    before do
      allow(Ocak::WorktreeManager).to receive(:new).and_return(worktrees)
      allow(instance).to receive(:build_logger).and_return(logger)
      allow(instance).to receive(:build_claude).and_return(claude)
      allow(instance).to receive(:run_pipeline).and_return(success_pipeline_result)
      allow(instance).to receive(:build_issue_result).and_return(
        { issue_number: 42, success: true, worktree: worktree }
      )
    end

    it 'transitions issue to in-progress' do
      instance.process_one_issue(ready_issue, worktrees: worktrees, issues: issues)
      expect(issues).to have_received(:transition).with(42, from: 'auto-ready', to: 'in-progress')
    end

    it 'creates a worktree for the issue' do
      instance.process_one_issue(ready_issue, worktrees: worktrees, issues: issues)
      expect(worktrees).to have_received(:create).with(42, setup_command: nil)
    end

    it 'calls run_pipeline with the issue number' do
      instance.process_one_issue(ready_issue, worktrees: worktrees, issues: issues)
      expect(instance).to have_received(:run_pipeline).with(42, anything)
    end

    it 'uses simple complexity when fast option is set' do
      host = test_class.new(config: config, options: { fast: true }, executor: executor)
      allow(host).to receive(:build_logger).and_return(logger)
      allow(host).to receive(:build_claude).and_return(claude)
      allow(host).to receive(:run_pipeline).and_return(success_pipeline_result)
      allow(host).to receive(:build_issue_result).and_return({ issue_number: 42, success: true, worktree: worktree })

      host.process_one_issue(ready_issue, worktrees: worktrees, issues: issues)

      expect(host).to have_received(:run_pipeline) do |_num, **opts|
        expect(opts[:complexity]).to eq('simple')
      end
    end

    it 'returns error result on StandardError' do
      allow(instance).to receive(:run_pipeline).and_raise(StandardError, 'unexpected')
      allow(instance).to receive(:handle_process_error)

      result = instance.process_one_issue(ready_issue, worktrees: worktrees, issues: issues)

      expect(result[:success]).to be false
      expect(result[:error]).to eq('unexpected')
    end

    it 'marks NameError as programming_error' do
      error = NoMethodError.new('undefined method')
      allow(instance).to receive(:run_pipeline).and_raise(error)
      allow(instance).to receive(:handle_process_error)

      result = instance.process_one_issue(ready_issue, worktrees: worktrees, issues: issues)

      expect(result[:programming_error]).to eq(error)
    end

    it 'removes issue from active_issues after processing' do
      active_issues = instance.instance_variable_get(:@active_issues)
      instance.process_one_issue(ready_issue, worktrees: worktrees, issues: issues)
      expect(active_issues).not_to include(42)
    end

    context 'when issue has _target' do
      let(:target) { { name: 'my-gem', path: '/dev/my-gem' } }
      let(:target_issue) { { 'number' => 42, 'title' => 'Fix bug', '_target' => target } }
      let(:target_worktrees) { instance_double(Ocak::WorktreeManager, create: worktree, remove: nil) }

      before do
        allow(Ocak::WorktreeManager).to receive(:new)
          .with(config: config, repo_dir: '/dev/my-gem', logger: logger)
          .and_return(target_worktrees)
      end

      it 'creates WorktreeManager with repo_dir from target' do
        instance.process_one_issue(target_issue, worktrees: nil, issues: issues)
        expect(Ocak::WorktreeManager).to have_received(:new)
          .with(config: config, repo_dir: '/dev/my-gem', logger: logger)
      end

      it 'uses the target WorktreeManager to create worktree' do
        instance.process_one_issue(target_issue, worktrees: nil, issues: issues)
        expect(target_worktrees).to have_received(:create).with(42, setup_command: nil)
      end
    end

    context 'when issue has no _target' do
      it 'uses the shared worktrees instance' do
        instance.process_one_issue(ready_issue, worktrees: worktrees, issues: issues)
        expect(worktrees).to have_received(:create).with(42, setup_command: nil)
      end
    end
  end

  describe '#build_issue_result' do
    let(:issues) { instance_double(Ocak::IssueFetcher, transition: nil, comment: nil) }

    before do
      allow(instance).to receive(:handle_interrupted_issue)
      allow(instance).to receive(:report_pipeline_failure)
      allow(instance).to receive(:build_logger).and_return(logger)
    end

    it 'returns interrupted result when result is interrupted' do
      result = { interrupted: true, phase: 'implement' }
      outcome = instance.build_issue_result(result, issue_number: 42, worktree: worktree,
                                                    issues: issues, logger: logger)
      expect(outcome).to eq({ issue_number: 42, success: false, worktree: worktree, interrupted: true })
    end

    it 'calls handle_interrupted_issue when interrupted' do
      result = { interrupted: true, phase: 'implement' }
      instance.build_issue_result(result, issue_number: 42, worktree: worktree, issues: issues, logger: logger)
      expect(instance).to have_received(:handle_interrupted_issue)
        .with(42, worktree.path, 'implement', logger: logger, issues: issues)
    end

    it 'returns success result with audit info when result succeeds' do
      result = { success: true, audit_blocked: false, audit_output: nil }
      outcome = instance.build_issue_result(result, issue_number: 42, worktree: worktree,
                                                    issues: issues, logger: logger)
      expect(outcome).to include(issue_number: 42, success: true, worktree: worktree, audit_blocked: false)
    end

    it 'includes audit_blocked in success result' do
      result = { success: true, audit_blocked: true, audit_output: '🔴 blocked' }
      outcome = instance.build_issue_result(result, issue_number: 42, worktree: worktree,
                                                    issues: issues, logger: logger)
      expect(outcome[:audit_blocked]).to be true
    end

    it 'calls report_pipeline_failure when result fails' do
      result = { success: false, phase: 'implement', output: 'Error' }
      instance.build_issue_result(result, issue_number: 42, worktree: worktree, issues: issues, logger: logger)
      expect(instance).to have_received(:report_pipeline_failure)
    end

    it 'returns failure result without audit info when result fails' do
      result = { success: false, phase: 'implement', output: 'Error' }
      outcome = instance.build_issue_result(result, issue_number: 42, worktree: worktree,
                                                    issues: issues, logger: logger)
      expect(outcome).to eq({ issue_number: 42, success: false, worktree: worktree })
    end
  end

  describe '#resolve_targets' do
    let(:issue1) { { 'number' => 1, 'title' => 'Issue 1' } }
    let(:issue2) { { 'number' => 2, 'title' => 'Issue 2' } }
    let(:target) { { name: 'my-gem', path: '/dev/my-gem' } }

    it 'attaches resolved target to each issue' do
      allow(Ocak::TargetResolver).to receive(:resolve).and_return(target)

      result = instance.resolve_targets([issue1], logger: logger)

      expect(result.first['_target']).to eq(target)
    end

    it 'returns all issues when all targets resolve successfully' do
      allow(Ocak::TargetResolver).to receive(:resolve).and_return(target)

      result = instance.resolve_targets([issue1, issue2], logger: logger)

      expect(result.size).to eq(2)
    end

    it 'skips issues that raise TargetResolutionError' do
      err = Ocak::TargetResolver::TargetResolutionError
      allow(Ocak::TargetResolver).to receive(:resolve).with(issue1, config: config).and_raise(err, 'unknown')
      allow(Ocak::TargetResolver).to receive(:resolve).with(issue2, config: config).and_return(target)

      result = instance.resolve_targets([issue1, issue2], logger: logger)

      expect(result.map { |i| i['number'] }).to eq([2])
    end

    it 'logs error when an issue is skipped' do
      allow(Ocak::TargetResolver).to receive(:resolve)
        .and_raise(Ocak::TargetResolver::TargetResolutionError, 'unknown repo')

      instance.resolve_targets([issue1], logger: logger)

      expect(logger).to have_received(:error).with(/Skipping issue #1/)
    end

    it 'returns empty array when all issues fail to resolve' do
      allow(Ocak::TargetResolver).to receive(:resolve)
        .and_raise(Ocak::TargetResolver::TargetResolutionError, 'unknown')

      result = instance.resolve_targets([issue1, issue2], logger: logger)

      expect(result).to be_empty
    end

    it 'attaches nil target when TargetResolver returns nil' do
      allow(Ocak::TargetResolver).to receive(:resolve).and_return(nil)

      result = instance.resolve_targets([issue1], logger: logger)

      expect(result.first['_target']).to be_nil
    end
  end
end
