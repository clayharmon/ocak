# frozen_string_literal: true

module Ocak
  # Batch processing logic — process_issues, run_batch, process_one_issue, build_issue_result.
  # Extracted from PipelineRunner to reduce file size.
  module BatchProcessing
    private

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
        merger = build_merge_manager(logger: logger, issues: issues)
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
        report_pipeline_failure(issue_number, result, issues: issues, config: @config, logger: logger)
        { issue_number: issue_number, success: false, worktree: worktree }
      end
    end
  end
end
