# frozen_string_literal: true

require 'open3'
require 'securerandom'
require_relative '../config'
require_relative '../claude_runner'
require_relative '../git_utils'
require_relative '../issue_fetcher'
require_relative '../verification'
require_relative '../planner'
require_relative '../step_comments'
require_relative '../logger'

module Ocak
  module Commands
    class Hiz < Dry::CLI::Command
      include Verification
      include Planner
      include StepComments

      desc 'Fast-mode: implement an issue with Sonnet, create a PR (no merge)'

      argument :issue, type: :integer, required: true, desc: 'Issue number to process'
      option :watch, type: :boolean, default: false, desc: 'Stream agent activity to terminal'
      option :dry_run, type: :boolean, default: false, desc: 'Show pipeline plan without executing'
      option :verbose, type: :boolean, default: false, desc: 'Increase log detail'
      option :quiet, type: :boolean, default: false, desc: 'Suppress non-error output'

      STEP_MODELS = {
        'implementer' => 'sonnet',
        'reviewer' => 'haiku',
        'security-reviewer' => 'sonnet'
      }.freeze

      IMPLEMENT_STEP = { agent: 'implementer', role: 'implement' }.freeze

      REVIEW_STEPS = [
        { agent: 'reviewer',          role: 'review' },
        { agent: 'security-reviewer', role: 'security' }
      ].freeze

      HizState = Struct.new(:issues, :total_cost, :steps_run, :review_results)

      def call(issue:, **options)
        @config = Config.load
        issue_number = issue.to_i

        if options[:dry_run]
          print_dry_run(issue_number)
          return
        end

        logger = build_logger(issue_number)
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

        post_hiz_start_comment(issue_number, state: state)
        branch = create_branch(issue_number, chdir)

        failure = run_agents(issue_number, claude: claude, logger: logger, chdir: chdir, state: state)
        if failure
          duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time).round
          post_hiz_summary_comment(issue_number, duration, success: false, failed_phase: failure[:phase],
                                                           state: state)
          handle_failure(issue_number, failure[:phase], failure[:output], issues: state.issues, logger: logger)
          return
        end

        verification_failure = run_final_verification_step(issue_number, claude: claude, logger: logger,
                                                                         chdir: chdir, state: state)
        if verification_failure
          duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time).round
          post_hiz_summary_comment(issue_number, duration, success: false, failed_phase: 'final-verify',
                                                           state: state)
          handle_failure(issue_number, 'final-verify', verification_failure[:output],
                         issues: state.issues, logger: logger)
          return
        end

        duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time).round
        post_hiz_summary_comment(issue_number, duration, success: true, state: state)
        push_and_create_pr(issue_number, branch, logger: logger, chdir: chdir, state: state)
      end

      def run_agents(issue_number, claude:, logger:, chdir:, state:)
        result = run_step(IMPLEMENT_STEP, issue_number, claude: claude, logger: logger, chdir: chdir, state: state)
        state.steps_run += 1
        state.total_cost += result.cost_usd.to_f
        unless result.success?
          logger.error("Implementation failed for issue ##{issue_number}")
          return { phase: 'implement', output: result.output }
        end

        state.review_results = run_reviews_in_parallel(issue_number, claude: claude, logger: logger,
                                                                     chdir: chdir, state: state)
        nil
      end

      def create_branch(issue_number, chdir)
        branch = "hiz/issue-#{issue_number}-#{SecureRandom.hex(4)}"
        _, stderr, status = Open3.capture3('git', 'checkout', '-b', branch, chdir: chdir)
        raise "Failed to create branch #{branch}: #{stderr}" unless status.success?

        branch
      end

      def run_reviews_in_parallel(issue_number, claude:, logger:, chdir:, state:)
        threads = REVIEW_STEPS.map do |step|
          Thread.new do
            run_step(step, issue_number, claude: claude, logger: logger, chdir: chdir, state: state)
          rescue StandardError => e
            logger.error("#{step[:role]} thread failed: #{e.message}")
            nil
          end
        end

        results = {}
        threads.each_with_index do |thread, i|
          result = thread.value
          step = REVIEW_STEPS[i]
          if result
            state.steps_run += 1
            state.total_cost += result.cost_usd.to_f
            results[step[:role]] = result if result.blocking_findings? || result.warnings?
          end
          next if result.nil? || result.success?

          logger.warn("#{step[:role]} reported issues but continuing")
        end
        results
      end

      def run_step(step, issue_number, claude:, logger:, chdir:, state:)
        agent = step[:agent]
        role = step[:role]
        model = STEP_MODELS[agent]
        logger.info("--- Phase: #{role} (#{agent}) [#{model}] ---")
        post_step_comment(issue_number, "\u{1F504} **Phase: #{role}** (#{agent})", state: state)
        prompt = build_step_prompt(role, issue_number, nil)
        result = claude.run_agent(agent, prompt, chdir: chdir, model: model)
        post_step_completion_comment(issue_number, role, result, state: state)
        result
      end

      def run_final_verification_step(issue_number, claude:, logger:, chdir:, state:)
        return nil unless @config.test_command || @config.lint_check_command

        logger.info('--- Final verification ---')
        post_step_comment(issue_number, "\u{1F504} **Phase: final-verify** (verification)", state: state)
        result = run_final_checks(logger, chdir: chdir)

        unless result[:success]
          logger.warn('Final checks failed, attempting fix...')
          post_step_comment(issue_number,
                            "\u{26A0}\u{FE0F} **Final verification failed** \u2014 attempting auto-fix...",
                            state: state)
          fix_prompt = "Fix these test/lint failures:\n\n" \
                       "<verification_output>\n#{result[:output]}\n</verification_output>"
          claude.run_agent('implementer', fix_prompt,
                           chdir: chdir, model: STEP_MODELS['implementer'])
          result = run_final_checks(logger, chdir: chdir)
        end

        state.steps_run += 1
        if result[:success]
          post_step_comment(issue_number, "\u{2705} **Phase: final-verify** completed", state: state)
          nil
        else
          post_step_comment(issue_number, "\u{274C} **Phase: final-verify** failed", state: state)
          { success: false, phase: 'final-verify', output: result[:output] }
        end
      end

      def push_and_create_pr(issue_number, branch, logger:, chdir:, state:)
        commit_changes(issue_number, chdir, logger: logger)

        _, stderr, status = Open3.capture3('git', 'push', '-u', 'origin', branch, chdir: chdir)
        unless status.success?
          logger.error("Push failed: #{stderr}")
          handle_failure(issue_number, 'push', stderr, issues: state.issues, logger: logger)
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
          handle_failure(issue_number, 'pr-create', stderr, issues: state.issues, logger: logger)
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

      def handle_failure(issue_number, phase, output, issues:, logger:)
        logger.error("Issue ##{issue_number} failed at phase: #{phase}")
        issues.comment(issue_number,
                       "Hiz (fast mode) failed at phase: #{phase}\n\n```\n#{output.to_s[0..1000]}\n```")
        warn "Issue ##{issue_number} failed at phase: #{phase}"
        _, stderr, status = Open3.capture3('git', 'checkout', 'main', chdir: @config.project_dir)
        logger.warn("Cleanup checkout to main failed: #{stderr}") unless status.success?
      end

      def build_logger(issue_number)
        PipelineLogger.new(log_dir: File.join(@config.project_dir, @config.log_dir), issue_number: issue_number)
      end

      def post_step_comment(issue_number, body, state:)
        state.issues&.comment(issue_number, body)
      rescue StandardError
        nil
      end

      def post_step_completion_comment(issue_number, role, result, state:)
        duration = (result.duration_ms.to_f / 1000).round
        cost = format('%.3f', result.cost_usd.to_f)
        if result.success?
          post_step_comment(issue_number, "\u{2705} **Phase: #{role}** completed \u2014 #{duration}s | $#{cost}",
                            state: state)
        else
          post_step_comment(issue_number, "\u{274C} **Phase: #{role}** failed \u2014 #{duration}s | $#{cost}",
                            state: state)
        end
      end

      def post_hiz_start_comment(issue_number, state:)
        steps = "implement \u2192 review \u2225 security"
        steps += " \u2192 verify" if @config.test_command || @config.lint_check_command
        post_step_comment(issue_number, "\u{1F680} **Hiz (fast mode) started** \u2014 #{steps}", state: state)
      end

      def post_hiz_summary_comment(issue_number, duration, success:, state:, failed_phase: nil)
        total = 3 + (@config.test_command || @config.lint_check_command ? 1 : 0)
        cost = format('%.2f', state.total_cost)

        if success
          post_step_comment(issue_number,
                            "\u{2705} **Pipeline complete** \u2014 #{state.steps_run}/#{total} steps run " \
                            "| 0 skipped | $#{cost} total | #{duration}s",
                            state: state)
        else
          post_step_comment(issue_number,
                            "\u{274C} **Pipeline failed** at phase: #{failed_phase} \u2014 " \
                            "#{state.steps_run}/#{total} steps completed | $#{cost} total",
                            state: state)
        end
      end
    end
  end
end
