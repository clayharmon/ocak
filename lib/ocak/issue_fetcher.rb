# frozen_string_literal: true

require 'open3'
require 'json'

module Ocak
  class IssueFetcher
    def initialize(config:, logger: nil)
      @config = config
      @logger = logger
    end

    def fetch_ready
      stdout, _, status = Open3.capture3(
        'gh', 'issue', 'list',
        '--label', @config.label_ready,
        '--state', 'open',
        '--json', 'number,title,body,labels,author',
        '--limit', '50',
        chdir: @config.project_dir
      )
      return [] unless status.success?

      issues = JSON.parse(stdout)
      issues.reject! { |i| in_progress?(i) }
      issues.select! { |i| authorized_issue?(i) }
      issues
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

    def authorized_issue?(issue)
      authors = allowed_authors
      author_login = issue.dig('author', 'login')

      return true if authors.empty? && @config.allowed_authors.any?

      if authors.any? && authors.include?(author_login)
        check_comment_requirement(issue)
      elsif authors.empty?
        # Default: current user only
        if author_login == current_user
          check_comment_requirement(issue)
        else
          @logger&.warn("Skipping issue ##{issue['number']}: author '#{author_login}' not in allowed list")
          false
        end
      else
        @logger&.warn("Skipping issue ##{issue['number']}: author '#{author_login}' not in allowed list")
        false
      end
    end

    def check_comment_requirement(issue)
      phrase = @config.require_comment
      return true unless phrase

      # Check if an allowed author commented the required phrase
      comments = fetch_comments(issue['number'])
      authors = allowed_authors.empty? ? [current_user] : allowed_authors

      has_approval = comments.any? do |c|
        authors.include?(c.dig('author', 'login')) && c['body']&.strip == phrase
      end

      unless has_approval
        @logger&.warn("Skipping issue ##{issue['number']}: missing required '#{phrase}' comment from allowed author")
      end

      has_approval
    end

    def fetch_comments(issue_number)
      stdout, _, status = Open3.capture3(
        'gh', 'issue', 'view', issue_number.to_s,
        '--json', 'comments',
        chdir: @config.project_dir
      )
      return [] unless status.success?

      JSON.parse(stdout).fetch('comments', [])
    rescue JSON::ParserError
      []
    end

    def allowed_authors
      @config.allowed_authors
    end

    def current_user
      @current_user ||= begin
        stdout, _, status = Open3.capture3('gh', 'api', 'user', '--jq', '.login')
        status.success? ? stdout.strip : nil
      end
    end

    def run_gh(*)
      Open3.capture3('gh', *, chdir: @config.project_dir)
    end
  end
end
