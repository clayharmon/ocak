# frozen_string_literal: true

module Ocak
  # Shutdown orchestration logic — graceful/force shutdown, interrupt/error handling, summary.
  # Extracted from PipelineRunner to reduce file size.
  module ShutdownHandling
    def shutdown!
      count = @active_mutex.synchronize { @shutdown_count += 1 }

      if count >= 2
        force_shutdown!
      else
        graceful_shutdown!
      end
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
      @state_machine.mark_failed(issue_number)
      begin
        issues.comment(issue_number, "Unexpected #{error.class}: #{error.message}")
      rescue StandardError => e
        logger&.debug("Comment posting failed: #{e.message}")
        nil
      end
    end

    def handle_interrupted_issue(issue_number, worktree_path, step_name, logger:, issues:)
      if worktree_path
        GitUtils.commit_changes(chdir: worktree_path,
                                message: "wip: pipeline interrupted after step #{step_name} for issue ##{issue_number}",
                                logger: logger)
      end
      @state_machine&.mark_interrupted(issue_number)
      issues&.comment(issue_number,
                      "\u{26A0}\u{FE0F} Pipeline interrupted after #{step_name}. " \
                      "Resume with `ocak resume --issue #{issue_number}`.")
      @active_mutex.synchronize { @interrupted_issues << issue_number }
    rescue StandardError => e
      logger.warn("Failed to handle interrupted issue ##{issue_number}: #{e.message}")
    end
  end
end
