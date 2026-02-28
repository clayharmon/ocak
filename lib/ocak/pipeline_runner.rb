# frozen_string_literal: true

require 'json'
require 'open3'
require_relative 'pipeline_executor'
require_relative 'reready_processor'

module Ocak
  class PipelineRunner
    def initialize(config:, options: {})
      @config = config
      @options = options
      @watch_formatter = options[:watch] ? WatchFormatter.new : nil
      @shutting_down = false
      @active_issues = []
      @active_mutex = Mutex.new
      @executor = PipelineExecutor.new(config: config)
    end

    def run
      @options[:single] ? run_single(@options[:single]) : run_loop
    end

    def run_pipeline(issue_number, logger:, claude:, chdir: nil, skip_steps: [], complexity: 'full')
      @executor.run_pipeline(issue_number, logger: logger, claude: claude, chdir: chdir,
                                           skip_steps: skip_steps, complexity: complexity)
    end

    def shutdown!
      @shutting_down = true
      logger = build_logger
      logger.info('Graceful shutdown initiated...')

      issues = IssueFetcher.new(config: @config, logger: logger)
      @active_mutex.synchronize do
        @active_issues.each do |issue_number|
          logger.info("Returning issue ##{issue_number} to ready queue")
          issues.transition(issue_number, from: @config.label_in_progress, to: @config.label_ready)
        rescue StandardError => e
          logger.warn("Failed to reset issue ##{issue_number}: #{e.message}")
        end
      end
    end

    private

    def run_single(issue_number)
      logger = build_logger(issue_number: issue_number)
      claude = build_claude(logger)
      issues = IssueFetcher.new(config: @config)
      ensure_labels(issues, logger)
      @executor.issues = issues
      logger.info("Running single issue mode for ##{issue_number}")

      if @options[:dry_run]
        logger.info("[DRY RUN] Would run pipeline for issue ##{issue_number}")
        return
      end

      issues.transition(issue_number, from: @config.label_ready, to: @config.label_in_progress)
      result = run_pipeline(issue_number, logger: logger, claude: claude)

      if result[:success]
        if @config.audit_mode
          handle_single_audit(issue_number, logger: logger, claude: claude, issues: issues)
        elsif @config.manual_review
          handle_single_manual_review(issue_number, logger: logger, claude: claude, issues: issues)
        else
          claude.run_agent('merger', "Create a PR, merge it, and close issue ##{issue_number}",
                           chdir: @config.project_dir)
          issues.transition(issue_number, from: @config.label_in_progress, to: @config.label_completed)
          logger.info("Issue ##{issue_number} completed successfully")
        end
      else
        issues.transition(issue_number, from: @config.label_in_progress, to: @config.label_failed)
        issues.comment(issue_number,
                       "Pipeline failed at phase: #{result[:phase]}\n\n```\n#{result[:output][0..1000]}\n```")
        logger.error("Issue ##{issue_number} failed at phase: #{result[:phase]}")
      end
    end

    def run_loop
      logger = build_logger
      issues = IssueFetcher.new(config: @config, logger: logger)
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
        sleep @config.poll_interval
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
      worktrees = WorktreeManager.new(config: @config)

      threads = batch_issues.map do |issue|
        Thread.new { process_one_issue(issue, worktrees: worktrees, issues: issues) }
      end
      results = threads.map(&:value)

      merger = MergeManager.new(
        config: @config, claude: build_claude(logger), logger: logger, issues: issues, watch: @watch_formatter
      )
      claude = build_claude(logger)
      results.select { |r| r[:success] }.each do |result|
        merge_completed_issue(result, merger: merger, issues: issues, logger: logger, claude: claude)
      end

      results.each do |result|
        next unless result[:worktree]

        worktrees.remove(result[:worktree])
      rescue StandardError => e
        logger.warn("Failed to clean worktree for ##{result[:issue_number]}: #{e.message}")
      end
    end

    def process_one_issue(issue, worktrees:, issues:)
      issue_number = issue['number']
      logger = build_logger(issue_number: issue_number)
      claude = build_claude(logger)
      worktree = nil

      @active_mutex.synchronize { @active_issues << issue_number }
      issues.transition(issue_number, from: @config.label_ready, to: @config.label_in_progress)
      worktree = worktrees.create(issue_number, setup_command: @config.setup_command)
      logger.info("Created worktree at #{worktree.path} (branch: #{worktree.branch})")

      result = run_pipeline(issue_number, logger: logger, claude: claude, chdir: worktree.path,
                                          complexity: issue.fetch('complexity', 'full'))

      build_issue_result(result, issue_number: issue_number, worktree: worktree, issues: issues)
    rescue StandardError => e
      logger.error("Unexpected error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      issues.transition(issue_number, from: @config.label_in_progress, to: @config.label_failed)
      { issue_number: issue_number, success: false, worktree: worktree, error: e.message }
    ensure
      @active_mutex.synchronize { @active_issues.delete(issue_number) }
    end

    def build_issue_result(result, issue_number:, worktree:, issues:)
      if result[:success]
        { issue_number: issue_number, success: true, worktree: worktree }
      else
        issues.transition(issue_number, from: @config.label_in_progress, to: @config.label_failed)
        issues.comment(issue_number,
                       "Pipeline failed at phase: #{result[:phase]}\n\n```\n#{result[:output][0..1000]}\n```")
        { issue_number: issue_number, success: false, worktree: worktree }
      end
    end

    def merge_completed_issue(result, merger:, issues:, logger:, claude:)
      if @config.audit_mode
        handle_batch_audit(result, merger: merger, issues: issues, logger: logger, claude: claude)
      elsif @config.manual_review
        handle_batch_manual_review(result, merger: merger, issues: issues, logger: logger)
      elsif merger.merge(result[:issue_number], result[:worktree])
        issues.transition(result[:issue_number], from: @config.label_in_progress, to: @config.label_completed)
        logger.info("Issue ##{result[:issue_number]} merged successfully")
      else
        issues.transition(result[:issue_number], from: @config.label_in_progress, to: @config.label_failed)
        logger.error("Issue ##{result[:issue_number]} merge failed")
      end
    end

    def handle_single_manual_review(issue_number, logger:, claude:, issues:)
      claude.run_agent('merger',
                       "Create a PR for issue ##{issue_number} but do NOT merge it and do NOT close the issue",
                       chdir: @config.project_dir)
      issues.transition(issue_number, from: @config.label_in_progress, to: @config.label_awaiting_review)
      logger.info("Issue ##{issue_number} PR created (manual review mode)")
    end

    def handle_batch_manual_review(result, merger:, issues:, logger:)
      pr_number = merger.create_pr_only(result[:issue_number], result[:worktree])
      if pr_number
        issues.transition(result[:issue_number], from: @config.label_in_progress,
                                                 to: @config.label_awaiting_review)
        logger.info("Issue ##{result[:issue_number]} PR ##{pr_number} created (manual review mode)")
      else
        issues.transition(result[:issue_number], from: @config.label_in_progress, to: @config.label_failed)
        logger.error("Issue ##{result[:issue_number]} PR creation failed")
      end
    end

    def handle_single_audit(issue_number, logger:, claude:, issues:)
      audit_result = run_audit_gate(issue_number, logger: logger, claude: claude, chdir: @config.project_dir)

      if audit_has_findings?(audit_result)
        handle_single_manual_review(issue_number, logger: logger, claude: claude, issues: issues)
        post_audit_comment_single(audit_result, logger: logger, issues: issues)
      elsif @config.manual_review
        handle_single_manual_review(issue_number, logger: logger, claude: claude, issues: issues)
      else
        claude.run_agent('merger', "Create a PR, merge it, and close issue ##{issue_number}",
                         chdir: @config.project_dir)
        issues.transition(issue_number, from: @config.label_in_progress, to: @config.label_completed)
        logger.info("Issue ##{issue_number} completed successfully")
      end
    end

    def handle_batch_audit(result, merger:, issues:, logger:, claude:)
      audit_result = run_audit_gate(result[:issue_number], logger: logger, claude: claude,
                                                           chdir: result[:worktree].path)

      if audit_has_findings?(audit_result)
        create_pr_with_audit(result, audit_result, merger: merger, issues: issues, logger: logger)
      elsif @config.manual_review
        handle_batch_manual_review(result, merger: merger, issues: issues, logger: logger)
      elsif merger.merge(result[:issue_number], result[:worktree])
        issues.transition(result[:issue_number], from: @config.label_in_progress, to: @config.label_completed)
        logger.info("Issue ##{result[:issue_number]} merged successfully")
      else
        issues.transition(result[:issue_number], from: @config.label_in_progress, to: @config.label_failed)
        logger.error("Issue ##{result[:issue_number]} merge failed")
      end
    end

    def create_pr_with_audit(result, audit_result, merger:, issues:, logger:)
      pr_number = merger.create_pr_only(result[:issue_number], result[:worktree])
      if pr_number
        issues.pr_comment(pr_number, "## Audit Report\n\n#{audit_result.output}")
        issues.transition(result[:issue_number], from: @config.label_in_progress,
                                                 to: @config.label_awaiting_review)
        logger.info("Issue ##{result[:issue_number]} PR ##{pr_number} created (audit findings)")
      else
        issues.transition(result[:issue_number], from: @config.label_in_progress, to: @config.label_failed)
        logger.error("Issue ##{result[:issue_number]} PR creation failed")
      end
    end

    def run_audit_gate(issue_number, logger:, claude:, chdir:)
      logger.info("Running audit gate for issue ##{issue_number}")
      claude.run_agent('auditor', 'Audit the changed files. Run: git diff main --name-only', chdir: chdir)
    end

    def audit_has_findings?(result)
      # Treat agent failure as findings — err on the side of caution rather than auto-merging
      !result.success? || result.output.to_s.match?(/BLOCK|🔴/)
    end

    def post_audit_comment_single(audit_result, logger:, issues:)
      pr_number = find_pr_for_branch(logger: logger)
      unless pr_number
        logger.warn("Could not find PR to post audit comment — findings were: #{audit_result.output[0..200]}")
        return
      end

      issues.pr_comment(pr_number, "## Audit Report\n\n#{audit_result.output}")
      logger.info("Posted audit comment on PR ##{pr_number}")
    end

    def find_pr_for_branch(logger:)
      stdout, _, status = Open3.capture3('gh', 'pr', 'view', '--json', 'number', chdir: @config.project_dir)
      return nil unless status.success?

      data = JSON.parse(stdout)
      data['number']
    rescue JSON::ParserError => e
      logger.warn("Failed to find PR number: #{e.message}")
      nil
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
      worktrees = WorktreeManager.new(config: @config)
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
      PipelineLogger.new(log_dir: File.join(@config.project_dir, @config.log_dir), issue_number: issue_number)
    end

    def build_claude(logger)
      ClaudeRunner.new(config: @config, logger: logger, watch: @watch_formatter)
    end
  end
end
