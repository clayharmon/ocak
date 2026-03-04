# frozen_string_literal: true

require 'open3'
require 'fileutils'
require_relative 'command_runner'
require_relative 'pipeline_state'
require_relative 'run_report'
require_relative 'verification'
require_relative 'planner'
require_relative 'step_comments'
require_relative 'state_management'
require_relative 'step_execution'
require_relative 'parallel_execution'

module Ocak
  class PipelineExecutor
    include CommandRunner
    include Verification
    include Planner
    include StepComments
    include StateManagement
    include StepExecution
    include ParallelExecution

    attr_writer :issues

    def initialize(config:, issues: nil, shutdown_check: nil)
      @config = config
      @issues = issues
      @shutdown_check = shutdown_check
    end

    def run_pipeline(issue_number, logger:, claude:, chdir: nil, skip_steps: [], complexity: 'full', # rubocop:disable Metrics/ParameterLists
                     steps: nil, verification_model: nil,
                     post_start_comment: true, post_summary_comment: true,
                     skip_merge: false)
      @logger = logger
      @custom_steps = steps
      @verification_model = verification_model
      @post_summary_comment = post_summary_comment
      @skip_merge = skip_merge
      chdir ||= @config.project_dir
      logger.info("=== Starting pipeline for issue ##{issue_number} (#{complexity}) ===")

      report = RunReport.new(complexity: complexity)
      state = build_initial_state(complexity, report)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      post_pipeline_start_comment(issue_number, state) if post_start_comment

      failure = run_pipeline_steps(issue_number, state, logger: logger, claude: claude, chdir: chdir,
                                                        skip_steps: skip_steps)
      log_cost_summary(state[:total_cost], logger)

      return handle_interrupted(issue_number, state, report, logger) if state[:interrupted]
      return handle_failure(issue_number, state, failure, report, start_time) if failure

      failure = run_final_verification(issue_number, logger: logger, claude: claude, chdir: chdir)
      return handle_failure(issue_number, state, failure, report, start_time) if failure

      pipeline_state.delete(issue_number)
      finish_success(issue_number, state, report, start_time, logger)
    end

    private

    def build_initial_state(complexity, report)
      { last_review_output: nil, had_fixes: false, completed_steps: [], total_cost: 0.0,
        complexity: complexity, steps_run: 0, steps_skipped: 0,
        audit_output: nil, audit_blocked: false, report: report, step_results: {} }
    end

    def handle_interrupted(issue_number, state, report, logger)
      save_report(report, issue_number, success: false, failed_phase: 'interrupted')
      logger.info("=== Pipeline interrupted for issue ##{issue_number} ===")
      build_interrupted_result(state)
    end

    def handle_failure(issue_number, state, failure, report, start_time)
      save_report(report, issue_number, success: false, failed_phase: failure[:phase])
      post_failure_and_return(issue_number, state, failure, start_time)
    end

    def finish_success(issue_number, state, report, start_time, logger)
      duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time).round
      save_report(report, issue_number, success: true)
      post_pipeline_summary_comment(issue_number, state, duration, success: true) if @post_summary_comment
      logger.info("=== Pipeline complete for issue ##{issue_number} ===")
      { success: true, output: 'Pipeline completed successfully',
        audit_blocked: state[:audit_blocked], audit_output: state[:audit_output],
        step_results: state[:step_results], total_cost: state[:total_cost], steps_run: state[:steps_run] }
    end

    def build_interrupted_result(state)
      last_step = state[:completed_steps].any? ? active_steps[state[:completed_steps].last] : nil
      last_role = last_step ? symbolize(last_step)[:role].to_s : 'startup'
      { success: false, phase: last_role, output: 'Pipeline interrupted', interrupted: true,
        step_results: state[:step_results], total_cost: state[:total_cost], steps_run: state[:steps_run] }
    end

    def post_failure_and_return(issue_number, state, failure, start_time)
      duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time).round
      if @post_summary_comment
        post_pipeline_summary_comment(issue_number, state, duration, success: false,
                                                                     failed_phase: failure[:phase])
      end
      failure.merge(step_results: state[:step_results], total_cost: state[:total_cost],
                    steps_run: state[:steps_run])
    end

    def run_pipeline_steps(issue_number, state, logger:, claude:, chdir:, skip_steps: [])
      @skip_steps = skip_steps
      steps = active_steps
      idx = 0
      while idx < steps.size
        break if check_shutdown(state, logger)

        step = symbolize(steps[idx])
        if step[:parallel]
          group = collect_parallel_group(steps, idx)
          failure = run_parallel_group(group, issue_number, state, logger: logger, claude: claude, chdir: chdir)
          idx += group.size
        else
          failure = run_single_step(step, idx, issue_number, state, logger: logger, claude: claude, chdir: chdir)
          idx += 1
        end
        return failure if failure
      end
      nil
    end

    def check_shutdown(state, logger)
      return false unless @shutdown_check&.call

      logger.info('Shutdown requested, stopping pipeline')
      state[:interrupted] = true
    end

    def run_final_verification(issue_number, logger:, claude:, chdir:)
      run_verification_with_retry(logger: logger, claude: claude, chdir: chdir,
                                  model: @verification_model) do |body|
        post_step_comment(issue_number, body)
      end
    end

    def pipeline_state
      @pipeline_state ||= PipelineState.new(log_dir: File.join(@config.project_dir, @config.log_dir))
    end

    def current_branch(chdir, logger: nil)
      result = run_git('rev-parse', '--abbrev-ref', 'HEAD', chdir: chdir)
      if result.status.nil?
        logger&.debug("Could not determine current branch: #{result.error}")
        return nil
      end
      result.output
    rescue StandardError => e
      logger&.debug("Could not determine current branch: #{e.message}")
      nil
    end

    def active_steps
      @custom_steps || @config.steps
    end

    def post_pipeline_start_comment(issue_number, state)
      total = active_steps.size
      conditional = conditional_step_count(state)
      post_step_comment(issue_number,
                        "\u{1F680} **Pipeline started** \u2014 complexity: `#{state[:complexity]}` " \
                        "| steps: #{total} (#{conditional} may be skipped)")
    end

    def post_pipeline_summary_comment(issue_number, state, duration, success:, failed_phase: nil)
      total = active_steps.size
      cost = format('%.2f', state[:total_cost])

      if success
        post_step_comment(issue_number,
                          "\u{2705} **Pipeline complete** \u2014 #{state[:steps_run]}/#{total} steps run " \
                          "| #{state[:steps_skipped]} skipped | $#{cost} total | #{duration}s")
      else
        post_step_comment(issue_number,
                          "\u{274C} **Pipeline failed** at phase: #{failed_phase} \u2014 " \
                          "#{state[:steps_run]}/#{total} steps completed | $#{cost} total")
      end
    end

    def conditional_step_count(state)
      active_steps.count do |step|
        step = symbolize(step)
        step[:condition] ||
          (step[:complexity] == 'full' && state[:complexity] == 'simple') ||
          (step[:role].to_s == 'merge' && @config.manual_review) ||
          (step[:role].to_s == 'merge' && @config.audit_mode) # merge may be skipped if audit finds blocking issues
      end
    end

    def symbolize(hash)
      return hash unless hash.is_a?(Hash)

      hash.transform_keys(&:to_sym)
    end
  end
end
