# frozen_string_literal: true

require 'open3'
require 'securerandom'
require_relative '../config'
require_relative '../claude_runner'
require_relative '../issue_fetcher'
require_relative '../verification'
require_relative '../logger'

module Ocak
  module Commands
    class Hiz < Dry::CLI::Command
      include Verification

      desc 'Fast-mode: implement an issue with Sonnet, create a PR (no merge)'

      argument :issue, type: :integer, required: true, desc: 'Issue number to process'
      option :watch, type: :boolean, default: false, desc: 'Stream agent activity to terminal'

      MODEL = 'sonnet'

      STEPS = [
        { agent: 'implementer', role: 'implement' },
        { agent: 'reviewer',    role: 'review' },
        { agent: 'security-reviewer', role: 'security' }
      ].freeze

      def call(issue:, **options)
        @config = Config.load
        issue_number = issue.to_i
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

      def run_fast_pipeline(issue_number, claude:, logger:, issues:)
        chdir = @config.project_dir
        branch = create_branch(issue_number, chdir)

        failure = run_agents(issue_number, claude: claude, logger: logger, chdir: chdir)
        if failure
          handle_failure(issue_number, failure[:phase], failure[:output], issues: issues, logger: logger)
          return
        end

        verification_failure = run_final_verification_step(claude: claude, logger: logger, chdir: chdir)
        if verification_failure
          handle_failure(issue_number, 'final-verify', verification_failure[:output],
                         issues: issues, logger: logger)
          return
        end

        push_and_create_pr(issue_number, branch, logger: logger, issues: issues, chdir: chdir)
      end

      def run_agents(issue_number, claude:, logger:, chdir:)
        STEPS.each do |step|
          result = run_step(step, issue_number, claude: claude, logger: logger, chdir: chdir)
          next if result.success?

          if step[:role] == 'implement'
            logger.error("Implementation failed for issue ##{issue_number}")
            return { phase: 'implement', output: result.output }
          end

          logger.warn("#{step[:role]} reported issues but continuing")
        end
        nil
      end

      def create_branch(issue_number, chdir)
        branch = "hiz/issue-#{issue_number}-#{SecureRandom.hex(4)}"
        _, stderr, status = Open3.capture3('git', 'checkout', '-b', branch, chdir: chdir)
        raise "Failed to create branch #{branch}: #{stderr}" unless status.success?

        branch
      end

      def run_step(step, issue_number, claude:, logger:, chdir:)
        agent = step[:agent]
        role = step[:role]
        logger.info("--- Phase: #{role} (#{agent}) [sonnet] ---")
        prompt = build_prompt(role, issue_number)
        claude.run_agent(agent, prompt, chdir: chdir, model: MODEL)
      end

      def build_prompt(role, issue_number)
        case role
        when 'implement' then "Implement GitHub issue ##{issue_number}"
        when 'review'    then "Review the changes for GitHub issue ##{issue_number}. Run: git diff main"
        when 'security'  then "Security review changes for GitHub issue ##{issue_number}. Run: git diff main"
        else "Run #{role} for GitHub issue ##{issue_number}"
        end
      end

      def run_final_verification_step(claude:, logger:, chdir:)
        return nil unless @config.test_command || @config.lint_check_command

        logger.info('--- Final verification ---')
        result = run_final_checks(logger, chdir: chdir)
        return nil if result[:success]

        logger.warn('Final checks failed, attempting fix...')
        claude.run_agent('implementer',
                         "Fix these test/lint failures:\n\n#{result[:output]}",
                         chdir: chdir, model: MODEL)

        result = run_final_checks(logger, chdir: chdir)
        return nil if result[:success]

        { success: false, phase: 'final-verify', output: result[:output] }
      end

      def push_and_create_pr(issue_number, branch, logger:, issues:, chdir:)
        commit_changes(issue_number, chdir)

        _, stderr, status = Open3.capture3('git', 'push', '-u', 'origin', branch, chdir: chdir)
        unless status.success?
          logger.error("Push failed: #{stderr}")
          handle_failure(issue_number, 'push', stderr, issues: issues, logger: logger)
          return
        end

        issue_data = issues.view(issue_number)
        issue_title = issue_data&.dig('title')
        pr_title = issue_title ? "Fix ##{issue_number}: #{issue_title}" : "Fix ##{issue_number}"
        pr_body = "Automated PR for issue ##{issue_number} (hiz fast mode)\n\nCloses ##{issue_number}"

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
          handle_failure(issue_number, 'pr-create', stderr, issues: issues, logger: logger)
        end
      end

      def commit_changes(issue_number, chdir)
        stdout, = Open3.capture3('git', 'status', '--porcelain', chdir: chdir)
        return if stdout.strip.empty?

        Open3.capture3('git', 'add', '-A', chdir: chdir)
        Open3.capture3('git', 'commit', '-m', "feat: implement issue ##{issue_number} [hiz]",
                       chdir: chdir)
      end

      def handle_failure(issue_number, phase, output, issues:, logger:)
        logger.error("Issue ##{issue_number} failed at phase: #{phase}")
        issues.comment(issue_number,
                       "Hiz (fast mode) failed at phase: #{phase}\n\n```\n#{output.to_s[0..1000]}\n```")
        warn "Issue ##{issue_number} failed at phase: #{phase}"
        Open3.capture3('git', 'checkout', 'main', chdir: @config.project_dir)
      end

      def build_logger(issue_number)
        PipelineLogger.new(log_dir: File.join(@config.project_dir, @config.log_dir), issue_number: issue_number)
      end
    end
  end
end
