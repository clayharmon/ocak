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

      option :watch, type: :boolean, default: false, desc: 'Stream agent activity to terminal'
      option :single, type: :integer, desc: 'Run a single issue without worktrees'
      option :dry_run, type: :boolean, default: false, desc: 'Show what would happen'
      option :once, type: :boolean, default: false, desc: 'Process current batch and exit'
      option :max_parallel, type: :integer, desc: 'Max concurrent pipelines'
      option :poll_interval, type: :integer, desc: 'Seconds between polls'

      def call(**options)
        config = Config.load

        # CLI options override config
        config.data[:pipeline][:max_parallel] = options[:max_parallel] if options[:max_parallel]
        config.data[:pipeline][:poll_interval] = options[:poll_interval] if options[:poll_interval]

        runner = PipelineRunner.new(
          config: config,
          options: {
            watch: options[:watch],
            single: options[:single],
            dry_run: options[:dry_run],
            once: options[:once]
          }
        )

        runner.run
      rescue Config::ConfigNotFound => e
        warn "Error: #{e.message}"
        exit 1
      end
    end
  end
end
