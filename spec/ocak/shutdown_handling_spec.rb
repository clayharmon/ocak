# frozen_string_literal: true

require 'spec_helper'
require 'ocak/shutdown_handling'
require 'ocak/git_utils'

RSpec.describe Ocak::ShutdownHandling do
  let(:test_class) do
    Class.new do
      include Ocak::ShutdownHandling

      public :shutdown!, :print_shutdown_summary, :handle_process_error, :handle_interrupted_issue

      attr_reader :shutting_down, :shutdown_count, :interrupted_issues

      def initialize(config:, registry:)
        @config = config
        @registry = registry
        @shutting_down = false
        @shutdown_count = 0
        @active_mutex = Mutex.new
        @interrupted_issues = []
        @active_issues = []
      end
    end
  end

  let(:config) do
    instance_double(Ocak::Config,
                    label_in_progress: 'in-progress',
                    label_failed: 'pipeline-failed',
                    label_ready: 'auto-ready')
  end
  let(:registry) { instance_double(Ocak::ProcessRegistry, kill_all: nil) }
  let(:logger) { instance_double(Ocak::PipelineLogger, info: nil, warn: nil, error: nil, debug: nil) }
  let(:issues) { instance_double(Ocak::IssueFetcher, transition: nil, comment: nil) }

  subject(:instance) { test_class.new(config: config, registry: registry) }

  describe '#shutdown!' do
    it 'initiates graceful shutdown on first call' do
      instance.shutdown!
      expect(instance.shutting_down).to be true
    end

    it 'calls kill_all on second call' do
      instance.shutdown!
      instance.shutdown!
      expect(registry).to have_received(:kill_all)
    end

    it 'prints graceful message on first call' do
      expect { instance.shutdown! }.to output(/Graceful shutdown/).to_stderr
    end

    it 'prints force message on second call' do
      instance.shutdown!
      expect { instance.shutdown! }.to output(/Force shutdown/).to_stderr
    end

    it 'sets shutting_down to true on force shutdown' do
      instance.shutdown!
      instance.shutdown!
      expect(instance.shutting_down).to be true
    end
  end

  describe '#print_shutdown_summary' do
    it 'does nothing when no interrupted issues' do
      expect { instance.print_shutdown_summary }.not_to output.to_stderr
    end

    it 'prints each interrupted issue with resume command' do
      instance.instance_variable_set(:@interrupted_issues, [42, 99])
      output = capture_stderr { instance.print_shutdown_summary }
      expect(output).to include('Issue #42')
      expect(output).to include('ocak resume --issue 42')
      expect(output).to include('Issue #99')
    end
  end

  describe '#handle_process_error' do
    let(:error) { StandardError.new('something went wrong') }

    before { error.set_backtrace(['line 1', 'line 2']) }

    it 'logs error with class and message' do
      instance.handle_process_error(error, issue_number: 42, logger: logger, issues: issues)
      expect(logger).to have_received(:error).with(/Unexpected StandardError: something went wrong/)
    end

    it 'transitions issue to failed label' do
      instance.handle_process_error(error, issue_number: 42, logger: logger, issues: issues)
      expect(issues).to have_received(:transition)
        .with(42, from: 'in-progress', to: 'pipeline-failed')
    end

    it 'posts error comment on issue' do
      instance.handle_process_error(error, issue_number: 42, logger: logger, issues: issues)
      expect(issues).to have_received(:comment).with(42, /Unexpected StandardError/)
    end

    it 'swallows comment posting errors' do
      allow(issues).to receive(:comment).and_raise(StandardError, 'network error')
      expect do
        instance.handle_process_error(error, issue_number: 42, logger: logger, issues: issues)
      end.not_to raise_error
    end

    it 'logs debug when comment posting fails' do
      allow(issues).to receive(:comment).and_raise(StandardError, 'network error')
      instance.handle_process_error(error, issue_number: 42, logger: logger, issues: issues)
      expect(logger).to have_received(:debug).with(/Comment posting failed/)
    end
  end

  describe '#handle_interrupted_issue' do
    before do
      allow(Ocak::GitUtils).to receive(:commit_changes)
    end

    it 'commits wip changes when worktree_path is provided' do
      instance.handle_interrupted_issue(42, '/worktree', 'implement', logger: logger, issues: issues)
      expect(Ocak::GitUtils).to have_received(:commit_changes)
        .with(hash_including(chdir: '/worktree', message: /wip:.*42/))
    end

    it 'skips commit when worktree_path is nil' do
      instance.handle_interrupted_issue(42, nil, 'implement', logger: logger, issues: issues)
      expect(Ocak::GitUtils).not_to have_received(:commit_changes)
    end

    it 'transitions issue to ready label' do
      instance.handle_interrupted_issue(42, nil, 'implement', logger: logger, issues: issues)
      expect(issues).to have_received(:transition)
        .with(42, from: 'in-progress', to: 'auto-ready')
    end

    it 'posts interrupted comment with resume command' do
      instance.handle_interrupted_issue(42, nil, 'implement', logger: logger, issues: issues)
      expect(issues).to have_received(:comment).with(42, /ocak resume --issue 42/)
    end

    it 'adds issue to interrupted_issues list' do
      instance.handle_interrupted_issue(42, nil, 'implement', logger: logger, issues: issues)
      expect(instance.interrupted_issues).to include(42)
    end

    it 'swallows StandardError and logs warning' do
      allow(issues).to receive(:transition).and_raise(StandardError, 'API error')
      expect do
        instance.handle_interrupted_issue(42, nil, 'implement', logger: logger, issues: issues)
      end.not_to raise_error
      expect(logger).to have_received(:warn).with(/Failed to handle interrupted issue/)
    end
  end

  def capture_stderr(&)
    old_stderr = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old_stderr
  end
end
