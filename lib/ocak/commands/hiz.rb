# frozen_string_literal: true

require 'open3'
require 'securerandom'
require_relative '../config'
require_relative '../claude_runner'
require_relative '../git_utils'
require_relative '../issue_fetcher'
require_relative '../pipeline_executor'
require_relative '../step_comments'
require_relative '../logger'

module Ocak
  module Commands
    class Hiz < Dry::CLI::Command
      include StepComments

      desc 'Fast-mode: implement an issue with Sonnet, create a PR (no merge)'

      argument :issue, type: :integer, required: true, desc: 'Issue number to process'
      option :watch, type: :boolean, default: false, desc: 'Stream agent activity to terminal'
      option :dry_run, type: :boolean, default: false, desc: 'Show pipeline plan without executing'
      option :verbose, type: :boolean, default: false, desc: 'Increase log detail'
      option :quiet, type: :boolean, default: false, desc: 'Suppress non-error output'

      HIZ_STEPS = [
        { agent: 'implementer', role: 'implement', model: 'sonnet' },
        { agent: 'reviewer', role: 'review', model: 'haiku', parallel: true },
        { agent: 'security-reviewer', role: 'security', model: 'sonnet', parallel: true }
      ].freeze

      HizState = Struct.new(:issues, :total_cost, :steps_run, :review_results)

      def call(issue:, **options)
        @config = Config.load
        issue_number = issue.to_i

        if options[:dry_run]
          print_dry_run(issue_number)
          return
        end

        @logger = logger = build_logger(issue_number)
        watch_formatter = options[:watch] ? WatchFormatter.new : nil
        claude = ClaudeRunner.new(config: @config, logger: logger, watch: watch_formatter)
        issues = IssueFetcher.new(config: @config, logger: logger)

        logger.info("=== Hiz (fast mode) for issue ##{issue_number} ===")

        run_fast_pipeline(issue_number, claude: claude, logger: logger, issues: issues)
      rescue Config::ConfigNotFound => e
        warn "Error: #{e.message}"
        exit 1
      end

      private

      def print_dry_run(issue_number)
        puts "[DRY RUN] Hiz pipeline for issue ##{issue_number}:"
        puts '  1. implement (implementer) [sonnet]'
        puts '  2. review (reviewer) [haiku] || security (security-reviewer) [sonnet]'
        has_verify = @config.test_command || @config.lint_check_command
        puts '  3. final-verify (verification)' if has_verify
      end

      def run_fast_pipeline(issue_number, claude:, logger:, issues:)
        state = HizState.new(issues, 0.0, 0, {})
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        chdir = @config.project_dir

        issues.transition(issue_number, from: @config.label_ready, to: @config.label_in_progress)
        post_hiz_start_comment(issue_number, state: state)
        begin
          branch = create_branch(issue_number, chdir)
        rescue RuntimeError => e
          fail_pipeline(issue_number, 'create-branch', e.message,
                        start_time: start_time, state: state, logger: logger)
          return
        end

        executor = PipelineExecutor.new(config: @config, issues: issues)
        result = executor.run_pipeline(
          issue_number, logger: logger, claude: claude, chdir: chdir,
                        steps: HIZ_STEPS, verification_model: 'sonnet',
                        post_start_comment: false, post_summary_comment: false
        )

        state.total_cost = result[:total_cost] || 0.0
        state.steps_run = result[:steps_run] || 0
        state.steps_run += 1 if verification_ran?(result)

        unless result[:success]
          fail_pipeline(issue_number, result[:phase], result[:output],
                        start_time: start_time, state: state, logger: logger, branch: branch)
          return
        end

        state.review_results = extract_review_results(result[:step_results])

        duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time).round
        post_hiz_summary_comment(issue_number, duration, success: true, state: state)
        push_and_create_pr(issue_number, branch, logger: logger, chdir: chdir, state: state)
      end

      def verification_ran?(result)
        (@config.test_command || @config.lint_check_command) &&
          (result[:success] || result[:phase] == 'final-verify')
      end

      def extract_review_results(step_results)
        return {} unless step_results

        step_results.select do |_role, r|
          r&.blocking_findings? || r&.warnings?
        end
      end

      def create_branch(issue_number, chdir)
        branch = "hiz/issue-#{issue_number}-#{SecureRandom.hex(4)}"
        raise "Unsafe branch name: #{branch}" unless GitUtils.safe_branch_name?(branch)

        _, stderr, status = Open3.capture3('git', 'checkout', '-b', branch, chdir: chdir)
        raise "Failed to create branch #{branch}: #{stderr}" unless status.success?

        branch
      end

      def push_and_create_pr(issue_number, branch, logger:, chdir:, state:)
        commit_changes(issue_number, chdir, logger: logger)

        _, stderr, status = Open3.capture3('git', 'push', '-u', 'origin', branch, chdir: chdir)
        unless status.success?
          logger.error("Push failed: #{stderr}")
          handle_failure(issue_number, 'push', stderr, issues: state.issues, logger: logger, branch: branch)
          return
        end

        issue_data = state.issues.view(issue_number)
        issue_title = issue_data&.dig('title')
        pr_title = issue_title ? "Fix ##{issue_number}: #{issue_title}" : "Fix ##{issue_number}"
        pr_body = build_pr_body(issue_number, state: state)

        stdout, stderr, status = Open3.capture3(
          'gh', 'pr', 'create',
          '--title', pr_title,
          '--body', pr_body,
          '--head', branch,
          chdir: chdir
        )

        if status.success?
          pr_url = stdout.strip
          logger.info("PR created: #{pr_url}")
          puts "PR created: #{pr_url}"
        else
          logger.error("PR creation failed: #{stderr}")
          handle_failure(issue_number, 'pr-create', stderr, issues: state.issues, logger: logger, branch: branch)
        end
      end

      def commit_changes(issue_number, chdir, logger:)
        GitUtils.commit_changes(
          chdir: chdir,
          message: "feat: implement issue ##{issue_number} [hiz]",
          logger: logger
        )
      end

      def build_pr_body(issue_number, state:)
        body = "Automated PR for issue ##{issue_number} (hiz fast mode)\n\nCloses ##{issue_number}"
        return body if state.review_results.nil? || state.review_results.empty?

        state.review_results.each do |role, result|
          heading = role == 'review' ? 'Review Findings' : 'Security Review Findings'
          body += "\n\n---\n\n## #{heading}\n\n#{result.output}"
        end
        body
      end

      def fail_pipeline(issue_number, phase, output, start_time:, state:, logger:, branch: nil) # rubocop:disable Metrics/ParameterLists
        duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time).round
        post_hiz_summary_comment(issue_number, duration, success: false, failed_phase: phase, state: state)
        handle_failure(issue_number, phase, output, issues: state.issues, logger: logger, branch: branch)
      end

      def handle_failure(issue_number, phase, output, issues:, logger:, branch: nil)
        logger.error("Issue ##{issue_number} failed at phase: #{phase}")
        issues.transition(issue_number, from: @config.label_in_progress, to: @config.label_failed)
        begin
          sanitized = output.to_s[0..1000].gsub('```', "'''")
          issues.comment(issue_number,
                         "Hiz (fast mode) failed at phase: #{phase}\n\n```\n#{sanitized}\n```")
        rescue StandardError
          nil
        end
        warn "Issue ##{issue_number} failed at phase: #{phase}"
        GitUtils.checkout_main(chdir: @config.project_dir, logger: logger)
        delete_branch(branch, logger: logger) if branch
      end

      def delete_branch(branch, logger:)
        _, stderr, status = Open3.capture3('git', 'branch', '-D', branch, chdir: @config.project_dir)
        logger.warn("Failed to delete branch #{branch}: #{stderr}") unless status.success?
      rescue StandardError => e
        logger.warn("Error deleting branch #{branch}: #{e.message}")
      end

      def build_logger(issue_number)
        PipelineLogger.new(log_dir: File.join(@config.project_dir, @config.log_dir), issue_number: issue_number)
      end

      def post_hiz_start_comment(issue_number, state:)
        steps = "implement \u2192 review \u2225 security"
        steps += " \u2192 verify" if @config.test_command || @config.lint_check_command
        post_step_comment(issue_number, "\u{1F680} **Hiz (fast mode) started** \u2014 #{steps}",
                          issues: state.issues)
      end

      def post_hiz_summary_comment(issue_number, duration, success:, state:, failed_phase: nil)
        total = 3 + (@config.test_command || @config.lint_check_command ? 1 : 0)
        cost = format('%.2f', state.total_cost)

        if success
          post_step_comment(issue_number,
                            "\u{2705} **Pipeline complete** \u2014 #{state.steps_run}/#{total} steps run " \
                            "| 0 skipped | $#{cost} total | #{duration}s",
                            issues: state.issues)
        else
          post_step_comment(issue_number,
                            "\u{274C} **Pipeline failed** at phase: #{failed_phase} \u2014 " \
                            "#{state.steps_run}/#{total} steps completed | $#{cost} total",
                            issues: state.issues)
        end
      end
    end
  end
end
