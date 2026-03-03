# frozen_string_literal: true

require_relative 'batch_processing'
require_relative 'failure_reporting'
require_relative 'instance_builders'
require_relative 'merge_orchestration'
require_relative 'pipeline_executor'
require_relative 'process_registry'
require_relative 'shutdown_handling'
require_relative 'git_utils'
require_relative 'issue_backend'
require_relative 'local_merge_manager'
require_relative 'reready_processor'

module Ocak
  class PipelineRunner
    include BatchProcessing
    include FailureReporting
    include InstanceBuilders
    include MergeOrchestration
    include ShutdownHandling

    attr_reader :registry

    def initialize(config:, options: {})
      @config = config
      @options = options
      @watch_formatter = options[:watch] ? WatchFormatter.new : nil
      @shutting_down = false
      @shutdown_count = 0
      @active_issues = []
      @interrupted_issues = []
      @active_mutex = Mutex.new
      @registry = ProcessRegistry.new
      @executor = PipelineExecutor.new(config: config, shutdown_check: -> { @shutting_down })
    end

    def run
      @options[:single] ? run_single(@options[:single]) : run_loop
    end

    def run_pipeline(issue_number, logger:, claude:, chdir: nil, skip_steps: [], complexity: 'full', # rubocop:disable Metrics/ParameterLists
                     skip_merge: false)
      @executor.run_pipeline(issue_number, logger: logger, claude: claude, chdir: chdir,
                                           skip_steps: skip_steps, complexity: complexity,
                                           skip_merge: skip_merge)
    end

    def shutting_down?
      @shutting_down
    end

    private

    def run_single(issue_number)
      logger = build_logger(issue_number: issue_number)
      claude = build_claude(logger)
      issues = IssueBackend.build(config: @config)
      ensure_labels(issues, logger)
      @executor.issues = issues
      logger.info("Running single issue mode for ##{issue_number}")

      if @options[:dry_run]
        logger.info("[DRY RUN] Would run pipeline for issue ##{issue_number}")
        return
      end

      issues.transition(issue_number, from: @config.label_ready, to: @config.label_in_progress)
      complexity = @options[:fast] ? 'simple' : 'full'
      result = run_pipeline(issue_number, logger: logger, claude: claude, complexity: complexity)

      if result[:interrupted]
        handle_interrupted_issue(issue_number, nil, result[:phase], logger: logger, issues: issues)
      elsif result[:success]
        handle_single_success(issue_number, result, logger: logger, claude: claude, issues: issues)
      else
        report_pipeline_failure(issue_number, result, issues: issues, config: @config, logger: logger)
        logger.error("Issue ##{issue_number} failed at phase: #{result[:phase]}")
      end
    end

    def run_loop
      logger = build_logger
      issues = IssueBackend.build(config: @config, logger: logger)
      ensure_labels(issues, logger)
      @executor.issues = issues
      cleanup_stale_worktrees(logger)

      loop do
        break if @shutting_down

        process_reready_prs(logger: logger, issues: issues) if @config.manual_review

        logger.info("Checking for #{@config.label_ready} issues...")
        ready = issues.fetch_ready

        if ready.empty?
          logger.info('No ready issues found')
        else
          logger.info("Found #{ready.size} ready issue(s): #{ready.map { |i| "##{i['number']}" }.join(', ')}")
          process_issues(ready, logger: logger, issues: issues)
        end

        break if @options[:once]

        logger.info("Sleeping #{@config.poll_interval}s...")
        @config.poll_interval.times do
          break if @shutting_down

          sleep 1
        end
      end
    end

    def process_reready_prs(logger:, issues:)
      reready = issues.fetch_reready_prs
      return if reready.empty?

      logger.info("Found #{reready.size} reready PR(s)")
      processor = RereadyProcessor.new(config: @config, logger: logger,
                                       claude: build_claude(logger), issues: issues,
                                       watch: @watch_formatter)
      reready.each do |pr|
        break if @shutting_down

        processor.process(pr)
      end
    end
  end
end
