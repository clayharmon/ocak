# frozen_string_literal: true

require 'spec_helper'
require 'ocak/pipeline_runner'

RSpec.describe Ocak::PipelineRunner do
  let(:config) do
    instance_double(Ocak::Config,
                    project_dir: '/project',
                    label_ready: 'auto-ready',
                    label_in_progress: 'in-progress',
                    label_completed: 'completed',
                    label_failed: 'pipeline-failed',
                    label_reready: 'auto-reready',
                    label_awaiting_review: 'auto-pending-human',
                    manual_review: false,
                    audit_mode: false,
                    log_dir: 'logs/pipeline',
                    poll_interval: 1,
                    max_parallel: 2,
                    max_issues_per_run: 5,
                    cost_budget: nil,
                    worktree_dir: '.claude/worktrees',
                    test_command: nil,
                    lint_command: nil,
                    lint_check_command: nil,
                    setup_command: nil,
                    language: 'ruby',
                    all_labels: %w[auto-ready in-progress completed pipeline-failed auto-reready auto-pending-human],
                    steps: [
                      { 'agent' => 'implementer', 'role' => 'implement' },
                      { 'agent' => 'reviewer', 'role' => 'review' },
                      { 'agent' => 'implementer', 'role' => 'fix', 'condition' => 'has_findings' }
                    ])
  end

  let(:logger) { instance_double(Ocak::PipelineLogger, info: nil, warn: nil, error: nil, debug: nil, log_file_path: nil) }
  let(:claude) { instance_double(Ocak::ClaudeRunner) }
  let(:issues) { instance_double(Ocak::IssueFetcher) }
  let(:pipeline_state) { instance_double(Ocak::PipelineState, save: nil, delete: nil, load: nil) }

  let(:success_result) { Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Done') }
  let(:failure_result) { Ocak::ClaudeRunner::AgentResult.new(success: false, output: 'Error') }
  let(:blocking_result) { Ocak::ClaudeRunner::AgentResult.new(success: true, output: "Found \u{1F534} issue") }

  before do
    allow(Ocak::PipelineLogger).to receive(:new).and_return(logger)
    allow(Ocak::ClaudeRunner).to receive(:new).and_return(claude)
    allow(Ocak::PipelineState).to receive(:new).and_return(pipeline_state)
    allow(Open3).to receive(:capture3)
      .with('git', 'rev-parse', '--abbrev-ref', 'HEAD', chdir: anything)
      .and_return(["main\n", '', instance_double(Process::Status, success?: true)])
    allow(FileUtils).to receive(:mkdir_p)
    allow(issues).to receive(:ensure_labels)
    allow(issues).to receive(:comment)
  end

  describe 'single issue mode' do
    subject(:runner) { described_class.new(config: config, options: { single: 42 }) }

    it 'runs pipeline and transitions labels on success' do
      allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
      allow(issues).to receive(:transition)
      allow(claude).to receive(:run_agent).and_return(success_result)

      runner.run

      expect(issues).to have_received(:transition).with(42, from: 'auto-ready', to: 'in-progress')
      expect(issues).to have_received(:transition).with(42, from: 'in-progress', to: 'completed')
    end

    it 'transitions to failed on pipeline failure' do
      allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
      allow(issues).to receive(:transition)
      allow(issues).to receive(:comment)
      allow(claude).to receive(:run_agent).with('implementer', anything, chdir: anything).and_return(failure_result)

      runner.run

      expect(issues).to have_received(:transition).with(42, from: 'in-progress', to: 'pipeline-failed')
    end

    it 'skips execution in dry run mode' do
      runner_dry = described_class.new(config: config, options: { single: 42, dry_run: true })
      allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)

      runner_dry.run

      expect(claude).not_to have_received(:run_agent) if claude.respond_to?(:run_agent)
    end

    it 'transitions to ready (not failed) on interrupted result' do
      allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
      allow(issues).to receive(:transition)
      allow(Ocak::GitUtils).to receive(:commit_changes)

      # Make the pipeline return an interrupted result
      allow(claude).to receive(:run_agent) do
        runner.instance_variable_set(:@shutting_down, true)
        success_result
      end

      runner.run

      expect(issues).to have_received(:transition).with(42, from: 'in-progress', to: 'auto-ready')
      expect(issues).not_to have_received(:transition).with(42, from: 'in-progress', to: 'pipeline-failed')
    end

    it 'posts interrupt comment (not failure comment) on interrupted result' do
      allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
      allow(issues).to receive(:transition)
      allow(Ocak::GitUtils).to receive(:commit_changes)

      allow(claude).to receive(:run_agent) do
        runner.instance_variable_set(:@shutting_down, true)
        success_result
      end

      runner.run

      expect(issues).to have_received(:comment).with(42, /Pipeline interrupted.*ocak resume --issue 42/)
      expect(issues).not_to have_received(:comment).with(42, /Pipeline failed/)
    end

    it 'adds interrupted issue to @interrupted_issues for shutdown summary' do
      allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
      allow(issues).to receive(:transition)
      allow(Ocak::GitUtils).to receive(:commit_changes)

      allow(claude).to receive(:run_agent) do
        runner.instance_variable_set(:@shutting_down, true)
        success_result
      end

      runner.run

      expect(runner.instance_variable_get(:@interrupted_issues)).to include(42)
    end
  end

  describe 'label auto-creation' do
    it 'calls ensure_labels in single issue mode' do
      runner = described_class.new(config: config, options: { single: 42 })
      allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
      allow(issues).to receive(:transition)
      allow(claude).to receive(:run_agent).and_return(success_result)

      runner.run

      expect(issues).to have_received(:ensure_labels).with(config.all_labels)
    end

    it 'calls ensure_labels in run_loop mode' do
      runner = described_class.new(config: config, options: { once: true })
      allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
      allow(Ocak::WorktreeManager).to receive(:new)
        .and_return(instance_double(Ocak::WorktreeManager, clean_stale: []))
      allow(issues).to receive(:fetch_ready).and_return([])

      runner.run

      expect(issues).to have_received(:ensure_labels).with(config.all_labels)
    end
  end

  describe 'pipeline step conditions' do
    subject(:runner) { described_class.new(config: config, options: { single: 10 }) }

    it 'skips fix step when no blocking findings' do
      allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
      allow(issues).to receive(:transition)

      # Implement succeeds
      allow(claude).to receive(:run_agent).with('implementer', anything, chdir: anything).and_return(success_result)
      # Review passes (no findings)
      allow(claude).to receive(:run_agent).with('reviewer', anything, chdir: anything).and_return(success_result)
      # Merger
      allow(claude).to receive(:run_agent).with('merger', anything, chdir: anything).and_return(success_result)

      runner.run

      # Fix step should be skipped — implementer called once for implement, not again for fix
      expect(claude).to have_received(:run_agent).with('implementer', anything, chdir: anything).once
    end

    it 'runs fix step when blocking findings present' do
      steps_with_fix = [
        { 'agent' => 'implementer', 'role' => 'implement' },
        { 'agent' => 'reviewer', 'role' => 'review' },
        { 'agent' => 'implementer', 'role' => 'fix', 'condition' => 'has_findings' },
        { 'agent' => 'merger', 'role' => 'merge' }
      ]
      allow(config).to receive(:steps).and_return(steps_with_fix)
      allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
      allow(issues).to receive(:transition)

      # Implement succeeds
      allow(claude).to receive(:run_agent).with('implementer', /Implement/, chdir: anything)
                                          .and_return(success_result)
      # Review finds blocking issues
      allow(claude).to receive(:run_agent).with('reviewer', anything, chdir: anything)
                                          .and_return(blocking_result)
      # Fix runs
      allow(claude).to receive(:run_agent).with('implementer', /Fix/, chdir: anything)
                                          .and_return(success_result)
      # Merger
      allow(claude).to receive(:run_agent).with('merger', anything, chdir: anything)
                                          .and_return(success_result)

      runner.run

      expect(claude).to have_received(:run_agent).with('implementer', /Fix/, chdir: anything).once
    end
  end

  describe 'complexity-based step skipping' do
    let(:steps_with_complexity) do
      [
        { 'agent' => 'implementer', 'role' => 'implement' },
        { 'agent' => 'reviewer', 'role' => 'review' },
        { 'agent' => 'security-reviewer', 'role' => 'security' },
        { 'agent' => 'documenter', 'role' => 'document', 'complexity' => 'full' },
        { 'agent' => 'auditor', 'role' => 'audit', 'complexity' => 'full' },
        { 'agent' => 'merger', 'role' => 'merge' }
      ]
    end

    before do
      allow(config).to receive(:steps).and_return(steps_with_complexity)
      allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
      allow(issues).to receive(:transition)
      allow(claude).to receive(:run_agent).and_return(success_result)
    end

    it 'skips full-complexity steps for simple issues' do
      runner = described_class.new(config: config, options: { single: 10 })

      # Patch run_single to pass complexity through
      allow(runner).to receive(:run_pipeline).and_wrap_original do |method, *args, **kwargs|
        method.call(*args, **kwargs, complexity: 'simple')
      end

      runner.run

      expect(claude).not_to have_received(:run_agent).with('documenter', anything, chdir: anything)
      expect(claude).not_to have_received(:run_agent).with('auditor', anything, chdir: anything)
    end

    it 'runs full-complexity steps for full issues' do
      runner = described_class.new(config: config, options: { single: 10 })
      runner.run

      expect(claude).to have_received(:run_agent).with('documenter', anything, chdir: anything)
      expect(claude).to have_received(:run_agent).with('auditor', anything, chdir: anything)
    end

    it 'always runs steps without complexity tag' do
      runner = described_class.new(config: config, options: { single: 10 })

      allow(runner).to receive(:run_pipeline).and_wrap_original do |method, *args, **kwargs|
        method.call(*args, **kwargs, complexity: 'simple')
      end

      runner.run

      expect(claude).to have_received(:run_agent).with('implementer', anything, chdir: anything)
      expect(claude).to have_received(:run_agent).with('reviewer', anything, chdir: anything)
      expect(claude).to have_received(:run_agent).with('security-reviewer', anything, chdir: anything)
    end

    it 'defaults to full complexity when not specified' do
      runner = described_class.new(config: config, options: { single: 10 })
      runner.run

      # All steps run including full-complexity ones
      expect(claude).to have_received(:run_agent).with('documenter', anything, chdir: anything)
    end
  end

  describe 'manual review mode' do
    context 'single issue mode' do
      subject(:runner) { described_class.new(config: config, options: { single: 42 }) }

      before do
        allow(config).to receive(:manual_review).and_return(true)
        allow(config).to receive(:label_awaiting_review).and_return('auto-pending-human')
        allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
        allow(issues).to receive(:transition)
        allow(claude).to receive(:run_agent).and_return(success_result)
      end

      it 'transitions to awaiting_review instead of completed' do
        runner.run

        expect(issues).to have_received(:transition)
          .with(42, from: 'in-progress', to: 'auto-pending-human')
      end

      it 'tells the merger not to merge or close the issue' do
        runner.run

        expect(claude).to have_received(:run_agent)
          .with('merger', /do NOT merge.*do NOT close/i, chdir: '/project')
      end
    end

    context 'batch mode' do
      subject(:runner) { described_class.new(config: config, options: { once: true }) }

      let(:worktree) do
        Ocak::WorktreeManager::Worktree.new(
          path: '/project/.claude/worktrees/issue-1',
          branch: 'auto/issue-1-abc',
          issue_number: 1
        )
      end
      let(:worktree_manager) do
        instance_double(Ocak::WorktreeManager, clean_stale: [], create: worktree, remove: nil)
      end
      let(:merger) do
        instance_double(Ocak::MergeManager)
      end

      before do
        allow(config).to receive(:manual_review).and_return(true)
        allow(config).to receive(:label_awaiting_review).and_return('auto-pending-human')
        allow(config).to receive(:label_reready).and_return('auto-reready')
        allow(Ocak::WorktreeManager).to receive(:new).and_return(worktree_manager)
        allow(Ocak::MergeManager).to receive(:new).and_return(merger)
        allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
        allow(issues).to receive(:fetch_ready).and_return([{ 'number' => 1, 'title' => 'A' }])
        allow(issues).to receive(:fetch_reready_prs).and_return([])
        allow(issues).to receive(:transition)
        allow(issues).to receive(:comment)
        allow(claude).to receive(:run_agent).and_return(success_result)
        allow(merger).to receive(:create_pr_only).and_return(55)
      end

      it 'calls create_pr_only instead of merge' do
        runner.run

        expect(merger).to have_received(:create_pr_only)
      end

      it 'transitions to awaiting_review on success' do
        runner.run

        expect(issues).to have_received(:transition)
          .with(1, from: 'in-progress', to: 'auto-pending-human')
      end

      it 'transitions to failed when PR creation fails' do
        allow(merger).to receive(:create_pr_only).and_return(nil)

        runner.run

        expect(issues).to have_received(:transition)
          .with(1, from: 'in-progress', to: 'pipeline-failed')
      end
    end

    context 'run_loop reready polling' do
      subject(:runner) { described_class.new(config: config, options: { once: true }) }

      before do
        allow(config).to receive(:manual_review).and_return(true)
        allow(config).to receive(:label_reready).and_return('auto-reready')
        allow(config).to receive(:label_awaiting_review).and_return('auto-pending-human')
        allow(Ocak::WorktreeManager).to receive(:new)
          .and_return(instance_double(Ocak::WorktreeManager, clean_stale: []))
        allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
        allow(issues).to receive(:fetch_ready).and_return([])
        allow(issues).to receive(:fetch_reready_prs).and_return([])
      end

      it 'checks for reready PRs before checking for ready issues' do
        runner.run

        expect(issues).to have_received(:fetch_reready_prs).ordered
        expect(issues).to have_received(:fetch_ready).ordered
      end
    end
  end

  describe 'audit gate' do
    let(:clean_audit) { Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'All checks passed') }
    let(:findings_audit) { Ocak::ClaudeRunner::AgentResult.new(success: true, output: "Found \u{1F534} hardcoded secret") }
    let(:block_audit) { Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'BLOCK: security issue') }
    let(:failed_audit) { Ocak::ClaudeRunner::AgentResult.new(success: false, output: 'Agent crashed') }
    let(:steps_with_audit) do
      [
        { 'agent' => 'implementer', 'role' => 'implement' },
        { 'agent' => 'reviewer', 'role' => 'review' },
        { 'agent' => 'auditor', 'role' => 'audit' }
      ]
    end

    context 'single mode + audit + findings' do
      subject(:runner) { described_class.new(config: config, options: { single: 42 }) }

      before do
        allow(config).to receive(:steps).and_return(steps_with_audit)
        allow(config).to receive(:audit_mode).and_return(true)
        allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
        allow(issues).to receive(:transition)
        allow(issues).to receive(:pr_comment)
        allow(claude).to receive(:run_agent).with('implementer', anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('reviewer', anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('merger', anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('auditor', anything, chdir: anything)
                                            .and_return(findings_audit)
        allow(Open3).to receive(:capture3)
          .with('gh', 'pr', 'view', '--json', 'number', chdir: '/project')
          .and_return(['{"number":99}', '', instance_double(Process::Status, success?: true)])
      end

      it 'creates PR and posts audit comment' do
        runner.run

        expect(claude).to have_received(:run_agent).with('auditor', anything, chdir: '/project')
        expect(claude).to have_received(:run_agent)
          .with('merger', /do NOT merge.*do NOT close/i, chdir: '/project')
        expect(issues).to have_received(:transition)
          .with(42, from: 'in-progress', to: 'auto-pending-human')
        expect(issues).to have_received(:pr_comment).with(99, /Audit Report/)
      end
    end

    context 'single mode + audit + BLOCK keyword' do
      subject(:runner) { described_class.new(config: config, options: { single: 42 }) }

      before do
        allow(config).to receive(:steps).and_return(steps_with_audit)
        allow(config).to receive(:audit_mode).and_return(true)
        allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
        allow(issues).to receive(:transition)
        allow(issues).to receive(:pr_comment)
        allow(claude).to receive(:run_agent).with('implementer', anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('reviewer', anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('merger', anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('auditor', anything, chdir: anything)
                                            .and_return(block_audit)
        allow(Open3).to receive(:capture3)
          .with('gh', 'pr', 'view', '--json', 'number', chdir: '/project')
          .and_return(['{"number":99}', '', instance_double(Process::Status, success?: true)])
      end

      it 'treats BLOCK keyword as findings' do
        runner.run

        expect(issues).to have_received(:transition)
          .with(42, from: 'in-progress', to: 'auto-pending-human')
      end
    end

    context 'single mode + audit + clean' do
      subject(:runner) { described_class.new(config: config, options: { single: 42 }) }

      before do
        allow(config).to receive(:steps).and_return(steps_with_audit)
        allow(config).to receive(:audit_mode).and_return(true)
        allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
        allow(issues).to receive(:transition)
        allow(claude).to receive(:run_agent).with('implementer', anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('reviewer', anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('merger', anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('auditor', anything, chdir: anything)
                                            .and_return(clean_audit)
      end

      it 'proceeds with normal auto-merge' do
        runner.run

        expect(claude).to have_received(:run_agent)
          .with('merger', /Create a PR, merge it, and close issue #42/, chdir: '/project')
        expect(issues).to have_received(:transition)
          .with(42, from: 'in-progress', to: 'completed')
      end
    end

    context 'single mode + audit + manual-review + findings' do
      subject(:runner) { described_class.new(config: config, options: { single: 42 }) }

      before do
        allow(config).to receive(:steps).and_return(steps_with_audit)
        allow(config).to receive(:audit_mode).and_return(true)
        allow(config).to receive(:manual_review).and_return(true)
        allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
        allow(issues).to receive(:transition)
        allow(issues).to receive(:pr_comment)
        allow(claude).to receive(:run_agent).with('implementer', anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('reviewer', anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('merger', anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('auditor', anything, chdir: anything)
                                            .and_return(findings_audit)
        allow(Open3).to receive(:capture3)
          .with('gh', 'pr', 'view', '--json', 'number', chdir: '/project')
          .and_return(['{"number":99}', '', instance_double(Process::Status, success?: true)])
      end

      it 'creates PR and posts audit comment' do
        runner.run

        expect(issues).to have_received(:transition)
          .with(42, from: 'in-progress', to: 'auto-pending-human')
        expect(issues).to have_received(:pr_comment).with(99, /Audit Report/)
      end
    end

    context 'single mode + audit + manual-review + clean' do
      subject(:runner) { described_class.new(config: config, options: { single: 42 }) }

      before do
        allow(config).to receive(:steps).and_return(steps_with_audit)
        allow(config).to receive(:audit_mode).and_return(true)
        allow(config).to receive(:manual_review).and_return(true)
        allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
        allow(issues).to receive(:transition)
        allow(claude).to receive(:run_agent).with('implementer', anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('reviewer', anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('merger', anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('auditor', anything, chdir: anything)
                                            .and_return(clean_audit)
      end

      it 'creates PR without audit comment (manual-review behavior)' do
        runner.run

        expect(claude).to have_received(:run_agent)
          .with('merger', /do NOT merge.*do NOT close/i, chdir: '/project')
        expect(issues).to have_received(:transition)
          .with(42, from: 'in-progress', to: 'auto-pending-human')
      end
    end

    context 'single mode + audit agent failure' do
      subject(:runner) { described_class.new(config: config, options: { single: 42 }) }

      before do
        allow(config).to receive(:steps).and_return(steps_with_audit)
        allow(config).to receive(:audit_mode).and_return(true)
        allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
        allow(issues).to receive(:transition)
        allow(issues).to receive(:pr_comment)
        allow(claude).to receive(:run_agent).with('implementer', anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('reviewer', anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('merger', anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('auditor', anything, chdir: anything)
                                            .and_return(failed_audit)
        allow(Open3).to receive(:capture3)
          .with('gh', 'pr', 'view', '--json', 'number', chdir: '/project')
          .and_return(['{"number":99}', '', instance_double(Process::Status, success?: true)])
      end

      it 'treats audit failure as findings — creates PR' do
        runner.run

        expect(issues).to have_received(:transition)
          .with(42, from: 'in-progress', to: 'auto-pending-human')
        expect(issues).to have_received(:pr_comment).with(99, /Audit Report/)
      end
    end

    context 'single mode + audit + findings + PR lookup fails' do
      subject(:runner) { described_class.new(config: config, options: { single: 42 }) }

      before do
        allow(config).to receive(:steps).and_return(steps_with_audit)
        allow(config).to receive(:audit_mode).and_return(true)
        allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
        allow(issues).to receive(:transition)
        allow(issues).to receive(:pr_comment)
        allow(claude).to receive(:run_agent).with('implementer', anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('reviewer', anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('merger', anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('auditor', anything, chdir: anything)
                                            .and_return(findings_audit)
        allow(Open3).to receive(:capture3)
          .with('gh', 'pr', 'view', '--json', 'number', chdir: '/project')
          .and_return(['', '', instance_double(Process::Status, success?: false)])
      end

      it 'transitions to awaiting review but does not post PR comment' do
        runner.run

        expect(issues).to have_received(:transition)
          .with(42, from: 'in-progress', to: 'auto-pending-human')
        expect(issues).not_to have_received(:pr_comment)
      end

      it 'logs a warning about the missing PR' do
        runner.run

        expect(logger).to have_received(:warn).with(/Could not find PR to post audit comment/)
      end
    end

    context 'batch mode + audit + findings' do
      subject(:runner) { described_class.new(config: config, options: { once: true }) }

      let(:worktree) do
        Ocak::WorktreeManager::Worktree.new(
          path: '/project/.claude/worktrees/issue-1',
          branch: 'auto/issue-1-abc',
          issue_number: 1
        )
      end
      let(:worktree_manager) do
        instance_double(Ocak::WorktreeManager, clean_stale: [], create: worktree, remove: nil)
      end
      let(:merger) { instance_double(Ocak::MergeManager) }

      before do
        allow(config).to receive(:steps).and_return(steps_with_audit)
        allow(config).to receive(:audit_mode).and_return(true)
        allow(Ocak::WorktreeManager).to receive(:new).and_return(worktree_manager)
        allow(Ocak::MergeManager).to receive(:new).and_return(merger)
        allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
        allow(issues).to receive(:fetch_ready).and_return([{ 'number' => 1, 'title' => 'A' }])
        allow(issues).to receive(:transition)
        allow(issues).to receive(:comment)
        allow(issues).to receive(:pr_comment)
        allow(claude).to receive(:run_agent).with(anything, anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('auditor', anything, chdir: anything)
                                            .and_return(findings_audit)
        allow(merger).to receive(:create_pr_only).and_return(55)
      end

      it 'creates PR and posts audit comment' do
        runner.run

        expect(merger).to have_received(:create_pr_only).with(1, worktree)
        expect(issues).to have_received(:pr_comment).with(55, /Audit Report/)
        expect(issues).to have_received(:transition)
          .with(1, from: 'in-progress', to: 'auto-pending-human')
      end
    end

    context 'batch mode + audit + clean' do
      subject(:runner) { described_class.new(config: config, options: { once: true }) }

      let(:worktree) do
        Ocak::WorktreeManager::Worktree.new(
          path: '/project/.claude/worktrees/issue-1',
          branch: 'auto/issue-1-abc',
          issue_number: 1
        )
      end
      let(:worktree_manager) do
        instance_double(Ocak::WorktreeManager, clean_stale: [], create: worktree, remove: nil)
      end
      let(:merger) { instance_double(Ocak::MergeManager) }

      before do
        allow(config).to receive(:steps).and_return(steps_with_audit)
        allow(config).to receive(:audit_mode).and_return(true)
        allow(Ocak::WorktreeManager).to receive(:new).and_return(worktree_manager)
        allow(Ocak::MergeManager).to receive(:new).and_return(merger)
        allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
        allow(issues).to receive(:fetch_ready).and_return([{ 'number' => 1, 'title' => 'A' }])
        allow(issues).to receive(:transition)
        allow(issues).to receive(:comment)
        allow(claude).to receive(:run_agent).with(anything, anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('auditor', anything, chdir: anything)
                                            .and_return(clean_audit)
        allow(merger).to receive(:merge).and_return(true)
      end

      it 'proceeds with normal merge' do
        runner.run

        expect(merger).to have_received(:merge).with(1, worktree)
        expect(issues).to have_received(:transition)
          .with(1, from: 'in-progress', to: 'completed')
      end
    end

    context 'batch mode + audit + manual-review + findings' do
      subject(:runner) { described_class.new(config: config, options: { once: true }) }

      let(:worktree) do
        Ocak::WorktreeManager::Worktree.new(
          path: '/project/.claude/worktrees/issue-1',
          branch: 'auto/issue-1-abc',
          issue_number: 1
        )
      end
      let(:worktree_manager) do
        instance_double(Ocak::WorktreeManager, clean_stale: [], create: worktree, remove: nil)
      end
      let(:merger) { instance_double(Ocak::MergeManager) }

      before do
        allow(config).to receive(:steps).and_return(steps_with_audit)
        allow(config).to receive(:audit_mode).and_return(true)
        allow(config).to receive(:manual_review).and_return(true)
        allow(Ocak::WorktreeManager).to receive(:new).and_return(worktree_manager)
        allow(Ocak::MergeManager).to receive(:new).and_return(merger)
        allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
        allow(issues).to receive(:fetch_ready).and_return([{ 'number' => 1, 'title' => 'A' }])
        allow(issues).to receive(:fetch_reready_prs).and_return([])
        allow(issues).to receive(:transition)
        allow(issues).to receive(:comment)
        allow(issues).to receive(:pr_comment)
        allow(claude).to receive(:run_agent).with(anything, anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('auditor', anything, chdir: anything)
                                            .and_return(findings_audit)
        allow(merger).to receive(:create_pr_only).and_return(55)
      end

      it 'creates PR with audit comment (audit_blocked takes priority over manual_review)' do
        runner.run

        expect(merger).to have_received(:create_pr_only).with(1, worktree)
        expect(issues).to have_received(:pr_comment).with(55, /Audit Report/)
        expect(issues).to have_received(:transition)
          .with(1, from: 'in-progress', to: 'auto-pending-human')
      end
    end

    context 'batch mode + audit + manual-review + clean' do
      subject(:runner) { described_class.new(config: config, options: { once: true }) }

      let(:worktree) do
        Ocak::WorktreeManager::Worktree.new(
          path: '/project/.claude/worktrees/issue-1',
          branch: 'auto/issue-1-abc',
          issue_number: 1
        )
      end
      let(:worktree_manager) do
        instance_double(Ocak::WorktreeManager, clean_stale: [], create: worktree, remove: nil)
      end
      let(:merger) { instance_double(Ocak::MergeManager) }

      before do
        allow(config).to receive(:steps).and_return(steps_with_audit)
        allow(config).to receive(:audit_mode).and_return(true)
        allow(config).to receive(:manual_review).and_return(true)
        allow(Ocak::WorktreeManager).to receive(:new).and_return(worktree_manager)
        allow(Ocak::MergeManager).to receive(:new).and_return(merger)
        allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
        allow(issues).to receive(:fetch_ready).and_return([{ 'number' => 1, 'title' => 'A' }])
        allow(issues).to receive(:fetch_reready_prs).and_return([])
        allow(issues).to receive(:transition)
        allow(issues).to receive(:comment)
        allow(claude).to receive(:run_agent).with(anything, anything, chdir: anything)
                                            .and_return(success_result)
        allow(claude).to receive(:run_agent).with('auditor', anything, chdir: anything)
                                            .and_return(clean_audit)
        allow(merger).to receive(:create_pr_only).and_return(77)
      end

      it 'creates PR without audit comment (manual-review behavior)' do
        runner.run

        expect(merger).to have_received(:create_pr_only).with(1, worktree)
        expect(issues).to have_received(:transition)
          .with(1, from: 'in-progress', to: 'auto-pending-human')
      end
    end
  end

  describe 'planner' do
    subject(:runner) { described_class.new(config: config, options: { once: true }) }

    let(:worktree) do
      Ocak::WorktreeManager::Worktree.new(
        path: '/project/.claude/worktrees/issue-1',
        branch: 'auto/issue-1-abc',
        issue_number: 1
      )
    end
    let(:worktree_manager) do
      instance_double(Ocak::WorktreeManager, clean_stale: [], create: worktree, remove: nil)
    end

    before do
      allow(Ocak::WorktreeManager).to receive(:new).and_return(worktree_manager)
    end

    it 'falls back to sequential batches when planner fails' do
      allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
      allow(issues).to receive(:fetch_ready).and_return([
                                                          { 'number' => 1, 'title' => 'A' },
                                                          { 'number' => 2, 'title' => 'B' }
                                                        ])
      allow(issues).to receive(:transition)
      allow(issues).to receive(:comment)

      allow(claude).to receive(:run_agent).with('planner', anything).and_return(failure_result)
      allow(claude).to receive(:run_agent).with(anything, anything, chdir: anything).and_return(failure_result)

      runner.run

      expect(claude).to have_received(:run_agent).with('planner', anything)
    end

    it 'returns sequential batches for single issue' do
      allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
      allow(issues).to receive(:fetch_ready).and_return([{ 'number' => 1, 'title' => 'A' }])
      allow(issues).to receive(:transition)
      allow(issues).to receive(:comment)
      allow(claude).to receive(:run_agent).and_return(failure_result)

      runner.run

      # Should not call planner for single issue
      expect(claude).not_to have_received(:run_agent).with('planner', anything)
    end
  end

  describe 'two-tiered shutdown' do
    subject(:runner) { described_class.new(config: config, options: { once: true }) }

    describe '#shutdown!' do
      it 'sets shutting_down flag on first call' do
        allow(runner).to receive(:warn)

        runner.shutdown!

        expect(runner.shutting_down?).to be true
      end

      it 'prints graceful shutdown message on first call' do
        expect { runner.shutdown! }.to output(/Graceful shutdown initiated/).to_stderr
      end

      it 'calls force_shutdown! on second call' do
        registry = runner.registry
        allow(registry).to receive(:kill_all)
        allow(runner).to receive(:warn)

        runner.shutdown!
        runner.shutdown!

        expect(registry).to have_received(:kill_all)
      end

      it 'prints force shutdown message on second call' do
        allow(runner.registry).to receive(:kill_all)

        expect do
          runner.shutdown!
          runner.shutdown!
        end.to output(/Force shutdown.*killing active processes/m).to_stderr
      end
    end

    describe '#print_shutdown_summary' do
      it 'outputs nothing when no issues were interrupted' do
        expect { runner.print_shutdown_summary }.not_to output.to_stderr
      end

      it 'outputs resume commands for interrupted issues' do
        # Simulate interrupted issues by accessing the internal state
        runner.instance_variable_get(:@interrupted_issues) << 42
        runner.instance_variable_get(:@interrupted_issues) << 99

        expect { runner.print_shutdown_summary }.to output(
          /Issue #42.*ocak resume --issue 42.*Issue #99.*ocak resume --issue 99/m
        ).to_stderr
      end
    end

    describe 'process_one_issue with shutdown' do
      let(:worktree) do
        Ocak::WorktreeManager::Worktree.new(
          path: '/project/.claude/worktrees/issue-1',
          branch: 'auto/issue-1-abc',
          issue_number: 1
        )
      end
      let(:worktree_manager) do
        instance_double(Ocak::WorktreeManager, clean_stale: [], create: worktree, remove: nil)
      end

      before do
        allow(Ocak::WorktreeManager).to receive(:new).and_return(worktree_manager)
        allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
        allow(issues).to receive(:fetch_ready).and_return([{ 'number' => 1, 'title' => 'A' }])
        allow(issues).to receive(:transition)
        allow(issues).to receive(:comment)
        allow(Ocak::GitUtils).to receive(:commit_changes).and_return(true)
      end

      it 'commits worktree changes when pipeline is interrupted' do
        # Make the pipeline return an interrupted result
        allow(claude).to receive(:run_agent) do
          runner.instance_variable_set(:@shutting_down, true)
          success_result
        end

        runner.run

        expect(Ocak::GitUtils).to have_received(:commit_changes).with(
          chdir: '/project/.claude/worktrees/issue-1',
          message: /wip: pipeline interrupted/,
          logger: anything
        )
      end

      it 'transitions issue back to ready on interruption' do
        allow(claude).to receive(:run_agent) do
          runner.instance_variable_set(:@shutting_down, true)
          success_result
        end

        runner.run

        expect(issues).to have_received(:transition).with(1, from: 'in-progress', to: 'auto-ready')
      end

      it 'posts interrupt comment on interrupted issue' do
        allow(claude).to receive(:run_agent) do
          runner.instance_variable_set(:@shutting_down, true)
          success_result
        end

        runner.run

        expect(issues).to have_received(:comment).with(
          1, /Pipeline interrupted.*ocak resume --issue 1/
        )
      end

      it 'does not crash when commit fails during shutdown and logs a warning' do
        allow(Ocak::GitUtils).to receive(:commit_changes).and_raise(StandardError, 'git error')
        allow(claude).to receive(:run_agent) do
          runner.instance_variable_set(:@shutting_down, true)
          success_result
        end

        expect { runner.run }.not_to raise_error
        expect(logger).to have_received(:warn).with(/Failed to handle interrupted issue/)
      end

      it 'does not crash when comment fails during shutdown and logs a warning' do
        allow(issues).to receive(:comment).and_raise(StandardError, 'network error')
        allow(claude).to receive(:run_agent) do
          runner.instance_variable_set(:@shutting_down, true)
          success_result
        end

        expect { runner.run }.not_to raise_error
        expect(logger).to have_received(:warn).with(/Failed to handle interrupted issue/)
      end

      it 'does not remove worktree for interrupted issues' do
        allow(claude).to receive(:run_agent) do
          runner.instance_variable_set(:@shutting_down, true)
          success_result
        end

        runner.run

        expect(worktree_manager).not_to have_received(:remove)
      end

      it 'skips merge phase when shutting down' do
        merger = instance_double(Ocak::MergeManager)
        allow(Ocak::MergeManager).to receive(:new).and_return(merger)
        allow(merger).to receive(:merge)

        allow(claude).to receive(:run_agent) do
          runner.instance_variable_set(:@shutting_down, true)
          success_result
        end

        runner.run

        expect(merger).not_to have_received(:merge)
      end
    end
  end

  describe 'process_one_issue unexpected error' do
    subject(:runner) { described_class.new(config: config, options: { once: true }) }

    let(:worktree) do
      Ocak::WorktreeManager::Worktree.new(
        path: '/project/.claude/worktrees/issue-1',
        branch: 'auto/issue-1-abc',
        issue_number: 1
      )
    end
    let(:worktree_manager) do
      instance_double(Ocak::WorktreeManager, clean_stale: [], create: worktree, remove: nil)
    end

    before do
      allow(Ocak::WorktreeManager).to receive(:new).and_return(worktree_manager)
      allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
      allow(issues).to receive(:fetch_ready).and_return([{ 'number' => 1, 'title' => 'A' }])
      allow(issues).to receive(:transition)
      allow(issues).to receive(:comment)
    end

    it 'transitions to failed label on unexpected error' do
      allow(claude).to receive(:run_agent).and_raise(StandardError, 'kaboom')

      runner.run

      expect(issues).to have_received(:transition).with(1, from: 'in-progress', to: 'pipeline-failed')
    end

    it 'includes error class name in the failure comment' do
      allow(claude).to receive(:run_agent).and_raise(RuntimeError, 'kaboom')

      runner.run

      expect(issues).to have_received(:comment).with(1, 'Unexpected RuntimeError: kaboom')
    end

    it 'includes error class name in the log message' do
      allow(claude).to receive(:run_agent).and_raise(RuntimeError, 'kaboom')

      runner.run

      expect(logger).to have_received(:error).with(/Unexpected RuntimeError: kaboom/)
    end

    it 'logs full backtrace at debug level' do
      allow(claude).to receive(:run_agent).and_raise(RuntimeError, 'kaboom')

      runner.run

      expect(logger).to have_received(:debug).with(/Full backtrace:.*pipeline_runner/m)
    end

    it 're-raises NameError after cleanup' do
      allow(claude).to receive(:run_agent).and_raise(NoMethodError, 'undefined method')

      expect { runner.run }.to raise_error(NoMethodError, 'undefined method')
      expect(issues).to have_received(:transition).with(1, from: 'in-progress', to: 'pipeline-failed')
      expect(issues).to have_received(:comment).with(1, /NoMethodError/)
    end

    it 're-raises TypeError after cleanup' do
      allow(claude).to receive(:run_agent).and_raise(TypeError, 'no implicit conversion')

      expect { runner.run }.to raise_error(TypeError, 'no implicit conversion')
      expect(issues).to have_received(:transition).with(1, from: 'in-progress', to: 'pipeline-failed')
      expect(issues).to have_received(:comment).with(1, /TypeError/)
    end

    it 'does not re-raise recoverable StandardError' do
      allow(claude).to receive(:run_agent).and_raise(RuntimeError, 'network timeout')

      expect { runner.run }.not_to raise_error
      expect(issues).to have_received(:transition).with(1, from: 'in-progress', to: 'pipeline-failed')
    end

    it 'returns error result when issues.comment raises during handle_process_error' do
      allow(claude).to receive(:run_agent).and_raise(RuntimeError, 'original error')
      allow(issues).to receive(:comment).and_raise(StandardError, 'GitHub API down')

      expect { runner.run }.not_to raise_error
      expect(issues).to have_received(:transition).with(1, from: 'in-progress', to: 'pipeline-failed')
    end
  end

  describe 'multi-issue batch with programming error' do
    subject(:runner) { described_class.new(config: config, options: { once: true }) }

    let(:worktree1) do
      Ocak::WorktreeManager::Worktree.new(
        path: '/project/.claude/worktrees/issue-1',
        branch: 'auto/issue-1-abc',
        issue_number: 1
      )
    end
    let(:worktree2) do
      Ocak::WorktreeManager::Worktree.new(
        path: '/project/.claude/worktrees/issue-2',
        branch: 'auto/issue-2-def',
        issue_number: 2
      )
    end
    let(:worktree_manager) { instance_double(Ocak::WorktreeManager, clean_stale: []) }
    let(:merger) { instance_double(Ocak::MergeManager) }

    before do
      allow(Ocak::WorktreeManager).to receive(:new).and_return(worktree_manager)
      allow(Ocak::MergeManager).to receive(:new).and_return(merger)
      allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
      allow(issues).to receive(:fetch_ready).and_return([
                                                          { 'number' => 1, 'title' => 'A' },
                                                          { 'number' => 2, 'title' => 'B' }
                                                        ])
      allow(issues).to receive(:transition)
      allow(issues).to receive(:comment)
      allow(worktree_manager).to receive(:remove)
      allow(worktree_manager).to receive(:create) do |num, **_opts|
        num == 1 ? worktree1 : worktree2
      end
    end

    it 'cleans up all worktrees and merges successful issues before re-raising' do
      planner_output = '{"batches": [{"batch": 1, "issues": [' \
                       '{"number": 1, "title": "A", "complexity": "full"}, ' \
                       '{"number": 2, "title": "B", "complexity": "full"}]}]}'
      planner_result = Ocak::ClaudeRunner::AgentResult.new(success: true, output: planner_output)

      allow(claude).to receive(:run_agent) do |agent, prompt, **_opts|
        if agent == 'planner'
          planner_result
        elsif prompt.include?('#1')
          raise NameError, 'undefined local variable'
        else
          success_result
        end
      end
      allow(merger).to receive(:merge).and_return(true)

      expect { runner.run }.to raise_error(NameError, 'undefined local variable')
      expect(worktree_manager).to have_received(:remove).with(worktree1)
      expect(worktree_manager).to have_received(:remove).with(worktree2)
      expect(merger).to have_received(:merge).with(2, worktree2)
    end
  end

  describe 'cleanup_stale_worktrees error' do
    subject(:runner) { described_class.new(config: config, options: { once: true }) }

    before do
      allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
      allow(issues).to receive(:fetch_ready).and_return([])
    end

    it 'warns and continues when cleanup raises' do
      allow(Ocak::WorktreeManager).to receive(:new).and_raise(StandardError, 'disk error')

      expect { runner.run }.not_to raise_error
      expect(logger).to have_received(:warn).with(/Stale worktree cleanup failed/)
    end
  end

  describe 'registry' do
    it 'creates a ProcessRegistry' do
      runner = described_class.new(config: config, options: {})

      expect(runner.registry).to be_a(Ocak::ProcessRegistry)
    end
  end
end
