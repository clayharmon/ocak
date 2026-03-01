# frozen_string_literal: true

require_relative 'failure_reporting'
require_relative 'merge_orchestration'
require_relative 'pipeline_executor'
require_relative 'process_registry'
require_relative 'git_utils'
require_relative 'issue_backend'
require_relative 'reready_processor'

module Ocak
  class PipelineRunner
    include FailureReporting
    include MergeOrchestration

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

    def run_pipeline(issue_number, logger:, claude:, chdir: nil, skip_steps: [], complexity: 'full')
      @executor.run_pipeline(issue_number, logger: logger, claude: claude, chdir: chdir,
                                           skip_steps: skip_steps, complexity: complexity)
    end

    def shutdown!
      count = @active_mutex.synchronize { @shutdown_count += 1 }

      if count >= 2
        force_shutdown!
      else
        graceful_shutdown!
      end
    end

    def shutting_down?
      @shutting_down
    end

    def print_shutdown_summary
      issues = @active_mutex.synchronize { @interrupted_issues.dup }
      return if issues.empty?

      warn "\nInterrupted issues:"
      issues.each do |issue_number|
        warn "  - Issue ##{issue_number}: ocak resume --issue #{issue_number}"
      end
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
        report_pipeline_failure(issue_number, result, issues: issues, config: @config)
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

    def process_issues(ready_issues, logger:, issues:)
      if ready_issues.size > @config.max_issues_per_run
        logger.warn("Capping to #{@config.max_issues_per_run} issues (found #{ready_issues.size})")
        ready_issues = ready_issues.first(@config.max_issues_per_run)
      end

      claude = build_claude(logger)
      batches = @executor.plan_batches(ready_issues, logger: logger, claude: claude)

      batches.each_with_index do |batch, idx|
        batch_issues = batch['issues'][0...@config.max_parallel]
        logger.info("Running batch #{idx + 1}/#{batches.size} (#{batch_issues.size} issues)")

        if @options[:dry_run]
          batch_issues.each { |i| logger.info("[DRY RUN] Would process issue ##{i['number']}: #{i['title']}") }
          next
        end

        run_batch(batch_issues, logger: logger, issues: issues)
      end
    end

    def run_batch(batch_issues, logger:, issues:)
      worktrees = WorktreeManager.new(config: @config, logger: logger)

      threads = batch_issues.map do |issue|
        Thread.new { process_one_issue(issue, worktrees: worktrees, issues: issues) }
      end
      results = threads.map(&:value)

      unless @shutting_down
        merger = MergeManager.new(
          config: @config, claude: build_claude(logger), logger: logger, issues: issues, watch: @watch_formatter
        )
        results.select { |r| r[:success] }.each do |result|
          merge_completed_issue(result, merger: merger, issues: issues, logger: logger)
        end
      end

      results.each do |result|
        next unless result[:worktree]
        next if result[:interrupted]

        worktrees.remove(result[:worktree])
      rescue StandardError => e
        logger.warn("Failed to clean worktree for ##{result[:issue_number]}: #{e.message}")
      end

      programming_error = results.find { |r| r[:programming_error] }&.dig(:programming_error)
      raise programming_error if programming_error
    end

    def process_one_issue(issue, worktrees:, issues:)
      issue_number = issue['number']
      logger = build_logger(issue_number: issue_number)
      claude = build_claude(logger)
      worktree = nil

      @active_mutex.synchronize do
        @active_issues << issue_number
      end
      issues.transition(issue_number, from: @config.label_ready, to: @config.label_in_progress)
      worktree = worktrees.create(issue_number, setup_command: @config.setup_command)
      logger.info("Created worktree at #{worktree.path} (branch: #{worktree.branch})")

      complexity = @options[:fast] ? 'simple' : issue.fetch('complexity', 'full')
      result = run_pipeline(issue_number, logger: logger, claude: claude, chdir: worktree.path,
                                          complexity: complexity)

      build_issue_result(result, issue_number: issue_number, worktree: worktree, issues: issues,
                                 logger: logger)
    rescue StandardError => e
      handle_process_error(e, issue_number: issue_number, logger: logger, issues: issues)
      result = { issue_number: issue_number, success: false, worktree: worktree, error: e.message }
      # NameError includes NoMethodError
      result[:programming_error] = e if e.is_a?(NameError) || e.is_a?(TypeError)
      result
    ensure
      @active_mutex.synchronize { @active_issues.delete(issue_number) }
    end

    def build_issue_result(result, issue_number:, worktree:, issues:, logger: nil)
      if result[:interrupted]
        handle_interrupted_issue(issue_number, worktree&.path, result[:phase],
                                 logger: logger || build_logger(issue_number: issue_number), issues: issues)
        { issue_number: issue_number, success: false, worktree: worktree, interrupted: true }
      elsif result[:success]
        { issue_number: issue_number, success: true, worktree: worktree,
          audit_blocked: result[:audit_blocked], audit_output: result[:audit_output] }
      else
        report_pipeline_failure(issue_number, result, issues: issues, config: @config)
        { issue_number: issue_number, success: false, worktree: worktree }
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

    def cleanup_stale_worktrees(logger)
      worktrees = WorktreeManager.new(config: @config, logger: logger)
      removed = worktrees.clean_stale
      removed.each { |path| logger.info("Cleaned stale worktree: #{path}") }
    rescue StandardError => e
      logger.warn("Stale worktree cleanup failed: #{e.message}")
    end

    def ensure_labels(issues, logger)
      issues.ensure_labels(@config.all_labels)
    rescue StandardError => e
      logger.warn("Failed to ensure labels: #{e.message}")
    end

    def build_logger(issue_number: nil)
      PipelineLogger.new(log_dir: File.join(@config.project_dir, @config.log_dir),
                         issue_number: issue_number, log_level: @options.fetch(:log_level, :normal))
    end

    def build_claude(logger)
      ClaudeRunner.new(config: @config, logger: logger, watch: @watch_formatter, registry: @registry)
    end

    def graceful_shutdown!
      @shutting_down = true
      warn "\nGraceful shutdown initiated — finishing current agent step(s)..."
    end

    def force_shutdown!
      @shutting_down = true
      warn "\nForce shutdown — killing active processes..."
      @registry.kill_all
    end

    def handle_process_error(error, issue_number:, logger:, issues:)
      logger.error("Unexpected #{error.class}: #{error.message}\n#{error.backtrace&.first(5)&.join("\n")}")
      logger.debug("Full backtrace:\n#{error.backtrace&.join("\n")}")
      issues.transition(issue_number, from: @config.label_in_progress, to: @config.label_failed)
      begin
        issues.comment(issue_number, "Unexpected #{error.class}: #{error.message}")
      rescue StandardError
        nil
      end
    end

    def handle_interrupted_issue(issue_number, worktree_path, step_name, logger:, issues:)
      if worktree_path
        GitUtils.commit_changes(chdir: worktree_path,
                                message: "wip: pipeline interrupted after step #{step_name} for issue ##{issue_number}",
                                logger: logger)
      end
      issues&.transition(issue_number, from: @config.label_in_progress, to: @config.label_ready)
      issues&.comment(issue_number,
                      "\u{26A0}\u{FE0F} Pipeline interrupted after #{step_name}. " \
                      "Resume with `ocak resume --issue #{issue_number}`.")
      @active_mutex.synchronize { @interrupted_issues << issue_number }
    rescue StandardError => e
      logger.warn("Failed to handle interrupted issue ##{issue_number}: #{e.message}")
    end
  end
end
