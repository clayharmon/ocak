# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'shellwords'
require_relative 'pipeline_state'
require_relative 'verification'
require_relative 'planner'

module Ocak
  class PipelineRunner
    include Verification
    include Planner

    StepContext = Struct.new(:issue_number, :idx, :role, :result, :state, :logger, :chdir)

    def initialize(config:, options: {})
      @config = config
      @options = options
      @watch_formatter = options[:watch] ? WatchFormatter.new : nil
      @shutting_down = false
      @active_issues = []
      @active_mutex = Mutex.new
    end

    def run
      if @options[:single]
        run_single(@options[:single])
      else
        run_loop
      end
    end

    def shutdown!
      @shutting_down = true
      logger = build_logger
      logger.info('Graceful shutdown initiated...')

      # Transition any in-progress issues back to ready
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

    # --- Single Issue Mode ---

    def run_single(issue_number)
      logger = build_logger(issue_number: issue_number)
      claude = build_claude(logger)
      issues = IssueFetcher.new(config: @config)

      logger.info("Running single issue mode for ##{issue_number}")

      if @options[:dry_run]
        logger.info("[DRY RUN] Would run pipeline for issue ##{issue_number}")
        return
      end

      issues.transition(issue_number, from: @config.label_ready, to: @config.label_in_progress)

      result = run_pipeline(issue_number, logger: logger, claude: claude)

      if result[:success]
        claude.run_agent('merger', "Create a PR, merge it, and close issue ##{issue_number}",
                         chdir: @config.project_dir)
        issues.transition(issue_number, from: @config.label_in_progress, to: @config.label_completed)
        logger.info("Issue ##{issue_number} completed successfully")
      else
        issues.transition(issue_number, from: @config.label_in_progress, to: @config.label_failed)
        issues.comment(issue_number,
                       "Pipeline failed at phase: #{result[:phase]}\n\n```\n#{result[:output][0..1000]}\n```")
        logger.error("Issue ##{issue_number} failed at phase: #{result[:phase]}")
      end
    end

    # --- Poll Loop ---

    def run_loop
      logger = build_logger
      issues = IssueFetcher.new(config: @config, logger: logger)

      # Clean up stale worktrees from previous runs
      cleanup_stale_worktrees(logger)

      loop do
        break if @shutting_down

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

    # --- Batch Processing ---

    def process_issues(ready_issues, logger:, issues:)
      if ready_issues.size > @config.max_issues_per_run
        logger.warn("Capping to #{@config.max_issues_per_run} issues (found #{ready_issues.size})")
        ready_issues = ready_issues.first(@config.max_issues_per_run)
      end

      claude = build_claude(logger)
      batches = plan_batches(ready_issues, logger: logger, claude: claude)

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

      # Process issues in parallel
      threads = batch_issues.map do |issue|
        Thread.new { process_one_issue(issue, worktrees: worktrees, issues: issues) }
      end

      results = threads.map(&:value)

      # Merge successful issues sequentially
      results.select { |r| r[:success] }.each do |result|
        merger = MergeManager.new(
          config: @config, claude: build_claude(logger), logger: logger, watch: @watch_formatter
        )

        if merger.merge(result[:issue_number], result[:worktree])
          issues.transition(result[:issue_number], from: @config.label_in_progress, to: @config.label_completed)
          logger.info("Issue ##{result[:issue_number]} merged successfully")
        else
          issues.transition(result[:issue_number], from: @config.label_in_progress, to: @config.label_failed)
          logger.error("Issue ##{result[:issue_number]} merge failed")
        end
      end

      # Clean up all worktrees
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

      result = run_pipeline(issue_number, logger: logger, claude: claude, chdir: worktree.path)

      if result[:success]
        { issue_number: issue_number, success: true, worktree: worktree }
      else
        issues.transition(issue_number, from: @config.label_in_progress, to: @config.label_failed)
        issues.comment(issue_number,
                       "Pipeline failed at phase: #{result[:phase]}\n\n```\n#{result[:output][0..1000]}\n```")
        { issue_number: issue_number, success: false, worktree: worktree }
      end
    rescue StandardError => e
      logger.error("Unexpected error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      issues.transition(issue_number, from: @config.label_in_progress, to: @config.label_failed)
      { issue_number: issue_number, success: false, worktree: worktree, error: e.message }
    ensure
      @active_mutex.synchronize { @active_issues.delete(issue_number) }
    end

    # --- Pipeline Execution ---

    def run_pipeline(issue_number, logger:, claude:, chdir: nil, skip_steps: [])
      chdir ||= @config.project_dir
      logger.info("=== Starting pipeline for issue ##{issue_number} ===")

      state = { last_review_output: nil, had_fixes: false, completed_steps: [], total_cost: 0.0 }

      failure = run_pipeline_steps(issue_number, state, logger: logger, claude: claude, chdir: chdir,
                                                        skip_steps: skip_steps)
      log_cost_summary(state[:total_cost], logger)
      return failure if failure

      failure = run_final_verification(logger: logger, claude: claude, chdir: chdir)
      return failure if failure

      # Clean up state file on success
      pipeline_state.delete(issue_number)

      logger.info("=== Pipeline complete for issue ##{issue_number} ===")
      { success: true, output: 'Pipeline completed successfully' }
    end

    def run_pipeline_steps(issue_number, state, logger:, claude:, chdir:, skip_steps: [])
      @config.steps.each_with_index do |step, idx|
        step = symbolize(step)
        role = step[:role].to_s

        if skip_steps.include?(idx)
          logger.info("Skipping #{role} (already completed)")
          next
        end

        next if skip_step?(step, state, logger)

        result = execute_step(step, issue_number, state[:last_review_output], logger: logger, claude: claude,
                                                                              chdir: chdir)
        ctx = StepContext.new(issue_number, idx, role, result, state, logger, chdir)
        failure = record_step_result(ctx)
        return failure if failure
      end
      nil
    end

    def record_step_result(ctx)
      update_pipeline_state(ctx.role, ctx.result, ctx.state)
      ctx.state[:completed_steps] << ctx.idx
      ctx.state[:total_cost] += ctx.result.cost_usd.to_f
      save_step_progress(ctx)

      check_step_failure(ctx) || check_cost_budget(ctx.state, ctx.logger)
    end

    def save_step_progress(ctx)
      pipeline_state.save(ctx.issue_number,
                          completed_steps: ctx.state[:completed_steps],
                          worktree_path: ctx.chdir,
                          branch: current_branch(ctx.chdir))
    end

    def check_step_failure(ctx)
      return nil if ctx.result.success? || !%w[implement merge].include?(ctx.role)

      ctx.logger.error("#{ctx.role} failed")
      { success: false, phase: ctx.role, output: ctx.result.output }
    end

    def check_cost_budget(state, logger)
      return nil unless @config.cost_budget && state[:total_cost] > @config.cost_budget

      cost = format('%.2f', state[:total_cost])
      budget = format('%.2f', @config.cost_budget)
      logger.error("Cost budget exceeded ($#{cost}/$#{budget})")
      { success: false, phase: 'budget', output: "Cost budget exceeded: $#{cost}" }
    end

    def skip_step?(step, state, logger)
      role = step[:role].to_s
      condition = step[:condition]

      if condition == 'has_findings' && !state[:last_review_output]&.include?("\u{1F534}")
        logger.info("Skipping #{role} — no blocking findings")
        return true
      end
      if condition == 'had_fixes' && !state[:had_fixes]
        logger.info("Skipping #{role} — no fixes were made")
        return true
      end
      false
    end

    def execute_step(step, issue_number, review_output, logger:, claude:, chdir:)
      agent = step[:agent].to_s
      role = step[:role].to_s
      logger.info("--- Phase: #{role} (#{agent}) ---")
      prompt = build_step_prompt(role, issue_number, review_output)
      claude.run_agent(agent.tr('_', '-'), prompt, chdir: chdir)
    end

    def update_pipeline_state(role, result, state)
      case role
      when 'review', 'verify', 'security', 'audit'
        state[:last_review_output] = result.output
      when 'fix'
        state[:had_fixes] = true
        state[:last_review_output] = nil
      when 'implement'
        state[:last_review_output] = nil
      end
    end

    def run_final_verification(logger:, claude:, chdir:)
      return nil unless @config.test_command || @config.lint_check_command

      logger.info('--- Final verification ---')
      result = run_final_checks(logger, chdir: chdir)
      return nil if result[:success]

      logger.warn('Final checks failed, attempting fix...')
      claude.run_agent('implementer',
                       "Fix these test/lint failures:\n\n#{result[:output]}",
                       chdir: chdir)
      result = run_final_checks(logger, chdir: chdir)
      return nil if result[:success]

      { success: false, phase: 'final-verify', output: result[:output] }
    end

    # --- Cost ---

    def log_cost_summary(total_cost, logger)
      return if total_cost.zero?

      budget = @config.cost_budget
      budget_str = budget ? " / $#{format('%.2f', budget)} budget" : ''
      logger.info("Pipeline cost: $#{format('%.4f', total_cost)}#{budget_str}")
    end

    # --- Cleanup ---

    def cleanup_stale_worktrees(logger)
      worktrees = WorktreeManager.new(config: @config)
      removed = worktrees.clean_stale
      removed.each { |path| logger.info("Cleaned stale worktree: #{path}") }
    rescue StandardError => e
      logger.warn("Stale worktree cleanup failed: #{e.message}")
    end

    # --- Helpers ---

    def build_logger(issue_number: nil)
      PipelineLogger.new(
        log_dir: File.join(@config.project_dir, @config.log_dir),
        issue_number: issue_number
      )
    end

    def build_claude(logger)
      ClaudeRunner.new(config: @config, logger: logger, watch: @watch_formatter)
    end

    def pipeline_state
      @pipeline_state ||= PipelineState.new(log_dir: File.join(@config.project_dir, @config.log_dir))
    end

    def current_branch(chdir)
      stdout, = Open3.capture3('git', 'rev-parse', '--abbrev-ref', 'HEAD', chdir: chdir)
      stdout.strip
    rescue StandardError
      nil
    end

    def symbolize(hash)
      return hash unless hash.is_a?(Hash)

      hash.transform_keys(&:to_sym)
    end
  end
end
