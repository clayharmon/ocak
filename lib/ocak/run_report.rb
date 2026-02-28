# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'

module Ocak
  class RunReport
    REPORTS_DIR = '.ocak/reports'

    attr_reader :steps, :started_at, :finished_at, :success, :failed_phase, :complexity

    def initialize(complexity: 'full')
      @complexity = complexity
      @steps = []
      @started_at = Time.now.utc.iso8601
      @finished_at = nil
      @success = nil
      @failed_phase = nil
    end

    def record_step(index:, agent:, role:, status:, result: nil, skip_reason: nil)
      entry = { index: index, agent: agent, role: role, status: status }

      if status == 'completed' && result
        entry[:duration_s] = (result.duration_ms.to_f / 1000).round
        entry[:cost_usd] = result.cost_usd.to_f
        entry[:num_turns] = result.num_turns.to_i
        entry[:files_edited] = result.files_edited || []
      elsif status == 'skipped' && skip_reason
        entry[:skip_reason] = skip_reason
      end

      @steps << entry
    end

    def finish(success:, failed_phase: nil)
      @finished_at = Time.now.utc.iso8601
      @success = success
      @failed_phase = failed_phase
    end

    def save(issue_number, project_dir:)
      dir = File.join(project_dir, REPORTS_DIR)
      FileUtils.mkdir_p(dir)

      timestamp = Time.now.strftime('%Y%m%d%H%M%S')
      path = File.join(dir, "issue-#{issue_number}-#{timestamp}.json")
      File.write(path, JSON.pretty_generate(to_h(issue_number)))
      path
    end

    def to_h(issue_number)
      total_duration = ((Time.parse(@finished_at) - Time.parse(@started_at)).round if @started_at && @finished_at)
      total_cost = @steps.sum { |s| s[:cost_usd].to_f }

      {
        issue_number: issue_number,
        complexity: @complexity,
        success: @success,
        started_at: @started_at,
        finished_at: @finished_at,
        total_duration_s: total_duration,
        total_cost_usd: total_cost.round(4),
        steps: @steps,
        failed_phase: @failed_phase
      }
    end

    def self.load_all(project_dir:)
      dir = File.join(project_dir, REPORTS_DIR)
      return [] unless Dir.exist?(dir)

      Dir.glob(File.join(dir, 'issue-*.json')).filter_map do |path|
        JSON.parse(File.read(path), symbolize_names: true)
      rescue JSON::ParserError => e
        warn("Skipping malformed report #{File.basename(path)}: #{e.message}")
        nil
      end
    end
  end
end
