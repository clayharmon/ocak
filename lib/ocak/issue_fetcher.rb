# frozen_string_literal: true

require 'open3'
require 'json'

module Ocak
  class IssueFetcher
    def initialize(config:)
      @config = config
    end

    def fetch_ready
      stdout, _, status = Open3.capture3(
        'gh', 'issue', 'list',
        '--label', @config.label_ready,
        '--state', 'open',
        '--json', 'number,title,body,labels',
        '--limit', '50',
        chdir: @config.project_dir
      )
      return [] unless status.success?

      issues = JSON.parse(stdout)
      issues.reject { |i| in_progress?(i) }
    rescue JSON::ParserError
      []
    end

    def add_label(issue_number, label)
      run_gh('issue', 'edit', issue_number.to_s, '--add-label', label)
    end

    def remove_label(issue_number, label)
      run_gh('issue', 'edit', issue_number.to_s, '--remove-label', label)
    end

    def transition(issue_number, from:, to:)
      remove_label(issue_number, from) if from
      add_label(issue_number, to)
    end

    def comment(issue_number, body)
      run_gh('issue', 'comment', issue_number.to_s, '--body', body)
    end

    def view(issue_number, fields: 'number,title,body,labels')
      stdout, _, status = Open3.capture3(
        'gh', 'issue', 'view', issue_number.to_s,
        '--json', fields,
        chdir: @config.project_dir
      )
      return nil unless status.success?

      JSON.parse(stdout)
    rescue JSON::ParserError
      nil
    end

    private

    def in_progress?(issue)
      issue['labels']&.any? { |l| l['name'] == @config.label_in_progress }
    end

    def run_gh(*)
      Open3.capture3('gh', *, chdir: @config.project_dir)
    end
  end
end
