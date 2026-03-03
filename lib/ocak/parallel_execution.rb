# frozen_string_literal: true

module Ocak
  # Parallel group execution logic extracted from PipelineExecutor.
  # Includers must provide run_single_step method and symbolize helper.
  module ParallelExecution
    def collect_parallel_group(steps, start_idx)
      group = []
      idx = start_idx
      while idx < steps.size
        step = symbolize(steps[idx])
        break unless step[:parallel]

        group << [step, idx]
        idx += 1
      end
      group
    end

    def run_parallel_group(group, issue_number, state, logger:, claude:, chdir:)
      mutex = Mutex.new
      threads = group.map do |step, idx|
        Thread.new do
          run_single_step(step, idx, issue_number, state, logger: logger, claude: claude,
                                                          chdir: chdir, mutex: mutex)
        rescue StandardError => e
          logger.error("#{step[:role]} thread failed: #{e.message}")
          nil
        end
      end

      results = threads.map(&:value)
      results.compact.find { |r| r.is_a?(Hash) && !r[:success] }
    end
  end
end
