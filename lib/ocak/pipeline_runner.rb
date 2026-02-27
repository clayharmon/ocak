# frozen_string_literal: true

require 'json'
require 'fileutils'

module Ocak
  class PipelineRunner
    def initialize(config:, options: {})
      @config = config
      @options = options
      @watch_formatter = options[:watch] ? WatchFormatter.new : nil
    end

    def run
      if @options[:single]
        run_single(@options[:single])
      else
        run_loop
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
      issues = IssueFetcher.new(config: @config)

      loop do
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

      issues.transition(issue_number, from: @config.label_ready, to: @config.label_in_progress)
      worktree = worktrees.create(issue_number)
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
    end

    # --- Pipeline Execution ---

    def run_pipeline(issue_number, logger:, claude:, chdir: nil)
      chdir ||= @config.project_dir
      logger.info("=== Starting pipeline for issue ##{issue_number} ===")

      state = { last_review_output: nil, had_fixes: false }

      failure = run_pipeline_steps(issue_number, state, logger: logger, claude: claude, chdir: chdir)
      return failure if failure

      failure = run_final_verification(logger: logger, claude: claude, chdir: chdir)
      return failure if failure

      logger.info("=== Pipeline complete for issue ##{issue_number} ===")
      { success: true, output: 'Pipeline completed successfully' }
    end

    def run_pipeline_steps(issue_number, state, logger:, claude:, chdir:)
      @config.steps.each do |step|
        step = symbolize(step)
        role = step[:role].to_s

        next if skip_step?(step, state, logger)

        result = execute_step(step, issue_number, state[:last_review_output], logger: logger, claude: claude,
                                                                              chdir: chdir)
        update_pipeline_state(role, result, state)

        if !result.success? && %w[implement merge].include?(role)
          logger.error("#{role} failed")
          return { success: false, phase: role, output: result.output }
        end
      end
      nil
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
      return nil unless @config.test_command

      logger.info('--- Final verification ---')
      return nil if run_final_checks(logger, chdir: chdir)

      logger.warn('Final checks failed, attempting fix...')
      claude.run_agent('implementer', "Fix test and lint failures. Run: #{@config.test_command}", chdir: chdir)
      return nil if run_final_checks(logger, chdir: chdir)

      { success: false, phase: 'final-verify', output: 'Tests still failing after fix attempt' }
    end

    def build_step_prompt(role, issue_number, review_output)
      case role
      when 'implement'
        "Implement GitHub issue ##{issue_number}"
      when 'review', 'verify'
        "Review the changes for GitHub issue ##{issue_number}. Run: git diff main"
      when 'fix'
        "Fix these review findings for issue ##{issue_number}:\n\n#{review_output}"
      when 'security'
        "Security review changes for GitHub issue ##{issue_number}. Run: git diff main"
      when 'document'
        "Add documentation for changes in GitHub issue ##{issue_number}"
      when 'audit'
        "Audit the changed files for issue ##{issue_number}. Run: git diff main --name-only"
      when 'merge', 'create_pr'
        "Create a PR, merge it, and close issue ##{issue_number}"
      else
        "Run #{role} for GitHub issue ##{issue_number}"
      end
    end

    def run_final_checks(logger, chdir:)
      commands = [@config.test_command, @config.lint_command].compact
      failures = []

      commands.each do |cmd|
        _, _, status = Open3.capture3(cmd, chdir: chdir)
        failures << cmd unless status.success?
      end

      if failures.empty?
        logger.info('All checks passed')
        true
      else
        logger.warn("Checks failed: #{failures.join(', ')}")
        false
      end
    end

    # --- Planner ---

    def plan_batches(issues, logger:, claude:)
      return sequential_batches(issues) if issues.size <= 1

      issue_json = JSON.generate(issues.map { |i| { number: i['number'], title: i['title'] } })
      result = claude.run_agent(
        'planner',
        "Analyze these issues and output parallelization batches as JSON:\n\n#{issue_json}"
      )

      unless result.success?
        logger.warn('Planner failed, falling back to sequential')
        return sequential_batches(issues)
      end

      parse_planner_output(result.output, issues, logger)
    end

    def parse_planner_output(output, issues, logger)
      json_match = output.match(/\{[\s\S]*"batches"[\s\S]*\}/)
      if json_match
        parsed = JSON.parse(json_match[0])
        parsed['batches']
      else
        logger.warn('Could not parse planner output, falling back to sequential')
        sequential_batches(issues)
      end
    rescue JSON::ParserError => e
      logger.warn("JSON parse error from planner: #{e.message}")
      sequential_batches(issues)
    end

    def sequential_batches(issues)
      issues.map.with_index { |i, idx| { 'batch' => idx + 1, 'issues' => [i] } }
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

    def symbolize(hash)
      return hash unless hash.is_a?(Hash)

      hash.transform_keys(&:to_sym)
    end
  end
end
