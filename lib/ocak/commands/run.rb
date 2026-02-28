# frozen_string_literal: true

require_relative '../config'
require_relative '../pipeline_runner'
require_relative '../claude_runner'
require_relative '../issue_fetcher'
require_relative '../worktree_manager'
require_relative '../merge_manager'
require_relative '../logger'

module Ocak
  module Commands
    class Run < Dry::CLI::Command
      desc 'Run the issue processing pipeline'

      argument :issue, type: :integer, required: false, desc: 'Issue number (single-issue mode)'

      option :watch, type: :boolean, default: false, desc: 'Stream agent activity to terminal'
      option :dry_run, type: :boolean, default: false, desc: 'Show what would happen'
      option :once, type: :boolean, default: false, desc: 'Process current batch and exit'
      option :max_parallel, type: :integer, desc: 'Max concurrent pipelines'
      option :poll_interval, type: :integer, desc: 'Seconds between polls'
      option :manual_review, type: :boolean, default: false,
                             desc: 'Create PRs without auto-merge; wait for human review'
      option :audit, type: :boolean, default: false,
                     desc: 'Run auditor as post-pipeline gate; create PR with findings if issues found'
      option :verbose, type: :boolean, default: false, desc: 'Increase log detail'
      option :quiet, type: :boolean, default: false, desc: 'Suppress non-error output'

      def call(issue: nil, **options)
        config = Config.load

        # CLI options override config
        config.override(:max_parallel, options[:max_parallel]) if options[:max_parallel]
        config.override(:poll_interval, options[:poll_interval]) if options[:poll_interval]
        config.override(:manual_review, true) if options[:manual_review]
        config.override(:audit_mode, true) if options[:audit]

        log_level = resolve_log_level(options)

        runner = PipelineRunner.new(
          config: config,
          options: {
            watch: options[:watch],
            single: issue&.to_i,
            dry_run: options[:dry_run],
            once: options[:once],
            log_level: log_level
          }
        )

        setup_signal_handlers(runner)
        runner.run
      rescue Config::ConfigNotFound => e
        warn "Error: #{e.message}"
        exit 1
      end

      private

      def resolve_log_level(options)
        return :quiet if options[:quiet]
        return :verbose if options[:verbose]

        :normal
      end

      def setup_signal_handlers(runner)
        %w[INT TERM].each do |signal|
          trap(signal) do
            warn "\nReceived #{signal}, shutting down gracefully..."
            runner.shutdown!
            exit 0
          end
        end
      end
    end
  end
end
