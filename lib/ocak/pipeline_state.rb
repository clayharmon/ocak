# frozen_string_literal: true

require 'json'
require 'fileutils'

module Ocak
  class PipelineState
    def initialize(log_dir:, logger: nil)
      @log_dir = log_dir
      @logger = logger
    end

    def save(issue_number, completed_steps:, worktree_path: nil, branch: nil)
      FileUtils.mkdir_p(@log_dir)
      File.write(state_path(issue_number), JSON.pretty_generate({
                                                                  issue_number: issue_number,
                                                                  completed_steps: completed_steps,
                                                                  worktree_path: worktree_path,
                                                                  branch: branch,
                                                                  updated_at: Time.now.iso8601
                                                                }))
    rescue StandardError => e
      @logger&.warn("Pipeline state save failed for issue ##{issue_number}: #{e.message}") ||
        warn("Pipeline state save failed for issue ##{issue_number}: #{e.message}")
      nil
    end

    def load(issue_number)
      path = state_path(issue_number)
      return nil unless File.exist?(path)

      JSON.parse(File.read(path), symbolize_names: true)
    rescue ArgumentError, JSON::ParserError => e
      warn("Failed to parse pipeline state for issue ##{issue_number}: #{e.message}")
      nil
    end

    def delete(issue_number)
      path = state_path(issue_number)
      FileUtils.rm_f(path)
    rescue ArgumentError
      nil
    end

    def list
      Dir.glob(File.join(@log_dir, 'issue-*-state.json')).filter_map do |path|
        JSON.parse(File.read(path), symbolize_names: true)
      rescue JSON::ParserError => e
        warn("Failed to parse pipeline state file #{path}: #{e.message}")
        nil
      end
    end

    private

    def state_path(issue_number)
      raise ArgumentError, "Invalid issue number: #{issue_number}" unless issue_number.to_s.match?(/\A\d+\z/)

      File.join(@log_dir, "issue-#{issue_number}-state.json")
    end
  end
end
