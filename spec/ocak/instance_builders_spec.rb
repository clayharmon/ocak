# frozen_string_literal: true

require 'spec_helper'
require 'ocak/instance_builders'

RSpec.describe Ocak::InstanceBuilders do
  let(:test_class) do
    Class.new do
      include Ocak::InstanceBuilders

      public :build_logger, :build_claude, :build_merge_manager, :build_state_machine,
             :gh_available?, :cleanup_stale_worktrees, :ensure_labels

      def initialize(config:, options: {}, watch_formatter: nil, registry: nil)
        @config = config
        @options = options
        @watch_formatter = watch_formatter
        @registry = registry
      end
    end
  end

  let(:config) do
    instance_double(Ocak::Config,
                    project_dir: '/project',
                    log_dir: 'logs/pipeline')
  end
  let(:logger) { instance_double(Ocak::PipelineLogger, info: nil, warn: nil, error: nil, debug: nil) }
  let(:registry) { instance_double(Ocak::ProcessRegistry) }
  let(:issues) { instance_double(Ocak::IssueFetcher) }

  subject(:instance) { test_class.new(config: config, registry: registry) }

  describe '#build_logger' do
    before { allow(Ocak::PipelineLogger).to receive(:new).and_return(logger) }

    it 'creates a PipelineLogger with config log_dir' do
      instance.build_logger
      expect(Ocak::PipelineLogger).to have_received(:new)
        .with(hash_including(log_dir: '/project/logs/pipeline'))
    end

    it 'passes issue_number when provided' do
      instance.build_logger(issue_number: 42)
      expect(Ocak::PipelineLogger).to have_received(:new)
        .with(hash_including(issue_number: 42))
    end

    it 'defaults log_level to :normal when not in options' do
      instance.build_logger
      expect(Ocak::PipelineLogger).to have_received(:new)
        .with(hash_including(log_level: :normal))
    end

    it 'uses log_level from options when present' do
      host = test_class.new(config: config, options: { log_level: :verbose })
      host.build_logger
      expect(Ocak::PipelineLogger).to have_received(:new)
        .with(hash_including(log_level: :verbose))
    end

    it 'returns the logger instance' do
      result = instance.build_logger
      expect(result).to eq(logger)
    end
  end

  describe '#build_claude' do
    let(:claude) { instance_double(Ocak::ClaudeRunner) }

    before { allow(Ocak::ClaudeRunner).to receive(:new).and_return(claude) }

    it 'creates a ClaudeRunner with config and logger' do
      instance.build_claude(logger)
      expect(Ocak::ClaudeRunner).to have_received(:new)
        .with(hash_including(config: config, logger: logger))
    end

    it 'passes registry to ClaudeRunner' do
      instance.build_claude(logger)
      expect(Ocak::ClaudeRunner).to have_received(:new)
        .with(hash_including(registry: registry))
    end

    it 'returns the claude runner instance' do
      result = instance.build_claude(logger)
      expect(result).to eq(claude)
    end

    it 'passes watch_formatter when set' do
      watch = instance_double(Ocak::WatchFormatter)
      host = test_class.new(config: config, watch_formatter: watch)
      host.build_claude(logger)
      expect(Ocak::ClaudeRunner).to have_received(:new)
        .with(hash_including(watch: watch))
    end
  end

  describe '#build_state_machine' do
    it 'returns an IssueStateMachine instance' do
      result = instance.build_state_machine(issues)
      expect(result).to be_a(Ocak::IssueStateMachine)
    end
  end

  describe '#build_merge_manager' do
    let(:claude) { instance_double(Ocak::ClaudeRunner) }
    let(:merge_manager) { instance_double(Ocak::MergeManager) }
    let(:local_merge_manager) { instance_double(Ocak::LocalMergeManager) }

    before do
      allow(Ocak::MergeManager).to receive(:new).and_return(merge_manager)
      allow(Ocak::LocalMergeManager).to receive(:new).and_return(local_merge_manager)
      allow(Ocak::ClaudeRunner).to receive(:new).and_return(claude)
    end

    it 'builds MergeManager for regular IssueFetcher' do
      result = instance.build_merge_manager(logger: logger, issues: issues)
      expect(result).to eq(merge_manager)
    end

    it 'builds LocalMergeManager when issues is LocalIssueFetcher and gh unavailable' do
      local_issues = Ocak::LocalIssueFetcher.new(config: config)
      allow(Open3).to receive(:capture3).and_return(['', '', instance_double(Process::Status, success?: false)])

      result = instance.build_merge_manager(logger: logger, issues: local_issues)
      expect(result).to eq(local_merge_manager)
    end

    it 'builds MergeManager when issues is LocalIssueFetcher but gh is available' do
      local_issues = Ocak::LocalIssueFetcher.new(config: config)
      allow(Open3).to receive(:capture3).and_return(['ok', '', instance_double(Process::Status, success?: true)])

      result = instance.build_merge_manager(logger: logger, issues: local_issues)
      expect(result).to eq(merge_manager)
    end
  end

  describe '#gh_available?' do
    it 'returns true when gh command succeeds' do
      allow(Open3).to receive(:capture3)
        .with('gh', 'repo', 'view', '--json', 'name', chdir: '/project')
        .and_return(['ok', '', instance_double(Process::Status, success?: true)])

      expect(instance.gh_available?).to be true
    end

    it 'returns false when gh command fails' do
      allow(Open3).to receive(:capture3)
        .with('gh', 'repo', 'view', '--json', 'name', chdir: '/project')
        .and_return(['', 'error', instance_double(Process::Status, success?: false)])

      expect(instance.gh_available?).to be false
    end

    it 'returns false when gh is not installed (Errno::ENOENT)' do
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

      expect(instance.gh_available?).to be false
    end
  end

  describe '#cleanup_stale_worktrees' do
    let(:worktrees) { instance_double(Ocak::WorktreeManager, clean_stale: []) }

    before { allow(Ocak::WorktreeManager).to receive(:new).and_return(worktrees) }

    it 'calls clean_stale on WorktreeManager' do
      instance.cleanup_stale_worktrees(logger)
      expect(worktrees).to have_received(:clean_stale)
    end

    it 'logs each removed worktree path' do
      allow(worktrees).to receive(:clean_stale).and_return(['/path/to/wt1', '/path/to/wt2'])
      instance.cleanup_stale_worktrees(logger)
      expect(logger).to have_received(:info).with(/wt1/)
      expect(logger).to have_received(:info).with(/wt2/)
    end

    it 'swallows StandardError and logs warning' do
      allow(worktrees).to receive(:clean_stale).and_raise(StandardError, 'git error')
      expect { instance.cleanup_stale_worktrees(logger) }.not_to raise_error
      expect(logger).to have_received(:warn).with(/Stale worktree cleanup failed/)
    end
  end

  describe '#ensure_labels' do
    before { allow(issues).to receive(:ensure_labels) }

    it 'calls ensure_labels with all_labels from config' do
      all_labels = %w[auto-ready in-progress completed failed]
      allow(config).to receive(:all_labels).and_return(all_labels)

      instance.ensure_labels(issues, logger)

      expect(issues).to have_received(:ensure_labels).with(all_labels)
    end

    it 'swallows StandardError and logs warning' do
      allow(config).to receive(:all_labels).and_return([])
      allow(issues).to receive(:ensure_labels).and_raise(StandardError, 'API error')

      expect { instance.ensure_labels(issues, logger) }.not_to raise_error
      expect(logger).to have_received(:warn).with(/Failed to ensure labels/)
    end
  end
end
