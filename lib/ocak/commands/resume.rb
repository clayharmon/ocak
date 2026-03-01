# frozen_string_literal: true

require_relative '../config'
require_relative '../failure_reporting'
require_relative '../git_utils'
require_relative '../pipeline_runner'
require_relative '../pipeline_state'
require_relative '../claude_runner'
require_relative '../issue_backend'
require_relative '../worktree_manager'
require_relative '../merge_manager'
require_relative '../logger'

module Ocak
  module Commands
    class Resume < Dry::CLI::Command
      include FailureReporting

      desc 'Resume a failed pipeline from the last successful step'

      argument :issue, type: :integer, required: true, desc: 'Issue number to resume'
      option :watch, type: :boolean, default: false, desc: 'Stream agent activity to terminal'
      option :dry_run, type: :boolean, default: false, desc: 'Show what would re-run without executing'
      option :verbose, type: :boolean, default: false, desc: 'Increase log detail'
      option :quiet, type: :boolean, default: false, desc: 'Suppress non-error output'

      def call(issue:, **options)
        config = Config.load
        issue_number = issue.to_i
        saved = load_state(config, issue_number)

        print_resume_info(issue_number, saved, config)

        if options[:dry_run]
          print_dry_run(saved, config)
          return
        end

        chdir = resolve_worktree(config, saved)
        run_resumed_pipeline(config, issue_number, saved, chdir, options)
      rescue Config::ConfigNotFound => e
        warn "Error: #{e.message}"
        exit 1
      end

      private

      def load_state(config, issue_number)
        log_dir = File.join(config.project_dir, config.log_dir)
        state = PipelineState.new(log_dir: log_dir)
        saved = state.load(issue_number)
        unless saved
          warn "No saved state for issue ##{issue_number}. Nothing to resume."
          exit 1
        end
        saved
      end

      def print_resume_info(issue_number, saved, config)
        puts "Resuming issue ##{issue_number}"
        puts "  Completed steps: #{saved[:completed_steps].size}/#{config.steps.size}"
        puts "  Worktree: #{saved[:worktree_path]}"
        puts "  Branch: #{saved[:branch]}"
        puts ''
      end

      def print_dry_run(saved, config)
        completed = saved[:completed_steps] || []
        puts '[DRY RUN] Steps that would re-run:'
        config.steps.each_with_index do |step, idx|
          status = completed.include?(idx) ? 'skip (completed)' : 'run'
          puts "  #{idx + 1}. #{step['role']} (#{step['agent']}) — #{status}"
        end
      end

      def run_resumed_pipeline(config, issue_number, saved, chdir, options)
        log_dir = File.join(config.project_dir, config.log_dir)
        logger = PipelineLogger.new(log_dir: log_dir, issue_number: issue_number)
        watch_formatter = options[:watch] ? WatchFormatter.new : nil
        claude = ClaudeRunner.new(config: config, logger: logger, watch: watch_formatter)
        issues = IssueBackend.build(config: config, logger: logger)

        issues.transition(issue_number, from: config.label_failed, to: config.label_in_progress)

        runner = PipelineRunner.new(config: config, options: { watch: options[:watch] })
        result = runner.run_pipeline(issue_number,
                                     logger: logger, claude: claude, chdir: chdir,
                                     skip_steps: saved[:completed_steps])

        ctx = { config: config, issue_number: issue_number, saved: saved, chdir: chdir,
                issues: issues, claude: claude, logger: logger, watch: watch_formatter }
        handle_result(result, ctx)
      end

      def handle_result(result, ctx)
        if result[:success]
          attempt_merge(ctx)
        else
          report_pipeline_failure(ctx[:issue_number], result, issues: ctx[:issues], config: ctx[:config])
          warn "Issue ##{ctx[:issue_number]} failed again at phase: #{result[:phase]}"
        end
      end

      def attempt_merge(ctx)
        merger = MergeManager.new(config: ctx[:config], claude: ctx[:claude],
                                  logger: ctx[:logger], issues: ctx[:issues], watch: ctx[:watch])
        worktree = WorktreeManager::Worktree.new(
          path: ctx[:chdir], branch: ctx[:saved][:branch], issue_number: ctx[:issue_number]
        )

        if merger.merge(ctx[:issue_number], worktree)
          ctx[:issues].transition(ctx[:issue_number], from: ctx[:config].label_in_progress,
                                                      to: ctx[:config].label_completed)
          puts "Issue ##{ctx[:issue_number]} resumed and merged successfully!"
        else
          ctx[:issues].transition(ctx[:issue_number], from: ctx[:config].label_in_progress,
                                                      to: ctx[:config].label_failed)
          warn "Issue ##{ctx[:issue_number]} merge failed after resume"
        end
      end

      def resolve_worktree(config, saved)
        return saved[:worktree_path] if saved[:worktree_path] && Dir.exist?(saved[:worktree_path])

        recreate_from_branch(config, saved)
      end

      def recreate_from_branch(config, saved)
        unless saved[:branch]
          warn 'Worktree no longer exists and no branch saved. Cannot resume.'
          exit 1
        end

        unless GitUtils.safe_branch_name?(saved[:branch])
          warn "Unsafe branch name '#{saved[:branch]}'. Cannot resume."
          exit 1
        end

        _, _, status = Open3.capture3('git', 'rev-parse', '--verify', saved[:branch], chdir: config.project_dir)
        unless status.success?
          warn "Worktree no longer exists and branch '#{saved[:branch]}' not found. Cannot resume."
          exit 1
        end

        worktrees = WorktreeManager.new(config: config)
        wt = worktrees.create(saved[:issue_number], setup_command: config.setup_command)
        _, stderr, status = Open3.capture3('git', 'checkout', saved[:branch], chdir: wt.path)
        unless status.success?
          warn "Failed to checkout branch '#{saved[:branch]}': #{stderr}"
          exit 1
        end
        wt.path
      end
    end
  end
end
