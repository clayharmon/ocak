# frozen_string_literal: true

require 'open3'
require 'json'

module Ocak
  class IssueFetcher
    LABEL_COLORS = {
      'auto-ready' => '0E8A16',
      'auto-doing' => '1D76DB',
      'completed' => '6F42C1',
      'pipeline-failed' => 'D93F0B',
      'auto-reready' => 'FBCA04',
      'auto-pending-human' => 'F9D0C4'
    }.freeze

    def initialize(config:, logger: nil)
      @config = config
      @logger = logger
    end

    def fetch_ready
      stdout, _, status = run_gh(
        'issue', 'list',
        '--label', @config.label_ready,
        '--state', 'open',
        '--json', 'number,title,body,labels,author',
        '--limit', '50'
      )
      return [] unless status.success?

      issues = JSON.parse(stdout)
      issues.reject! { |i| in_progress?(i) }
      issues.select! { |i| authorized_issue?(i) }
      issues
    rescue JSON::ParserError => e
      @logger&.warn("Failed to parse issue list JSON: #{e.message}")
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

    def fetch_reready_prs
      stdout, _, status = run_gh(
        'pr', 'list',
        '--label', @config.label_reready,
        '--state', 'open',
        '--json', 'number,title,body,headRefName,labels',
        '--limit', '20'
      )
      return [] unless status.success?

      JSON.parse(stdout)
    rescue JSON::ParserError => e
      @logger&.warn("Failed to parse reready PRs JSON: #{e.message}")
      []
    end

    def fetch_pr_comments(pr_number)
      stdout, _, status = run_gh(
        'pr', 'view', pr_number.to_s,
        '--json', 'comments,reviews'
      )
      return { comments: [], reviews: [] } unless status.success?

      data = JSON.parse(stdout)
      { comments: data.fetch('comments', []), reviews: data.fetch('reviews', []) }
    rescue JSON::ParserError => e
      @logger&.warn("Failed to parse PR comments JSON: #{e.message}")
      { comments: [], reviews: [] }
    end

    def extract_issue_number_from_pr(pull_request)
      body = pull_request['body'].to_s
      match = body.match(/(?:closes|fixes|resolves)\s+#(\d+)/i)
      match ? match[1].to_i : nil
    end

    def pr_transition(pr_number, remove_label: nil, add_label: nil)
      if remove_label
        _, _, status = run_gh('pr', 'edit', pr_number.to_s, '--remove-label', remove_label)
        return false unless status.success?
      end

      if add_label
        _, _, status = run_gh('pr', 'edit', pr_number.to_s, '--add-label', add_label)
        return false unless status.success?
      end

      true
    end

    def pr_comment(pr_number, body)
      _, _, status = run_gh('pr', 'comment', pr_number.to_s, '--body', body)
      status.success?
    end

    def ensure_labels(labels)
      labels.each { |label| ensure_label(label) }
    end

    def ensure_label(label)
      color = LABEL_COLORS.fetch(label, 'ededed')
      run_gh('label', 'create', label, '--force', '--color', color) # --force: update if exists
    rescue Errno::ENOENT => e
      @logger&.warn("Failed to create label '#{label}': #{e.message}")
    end

    def view(issue_number, fields: 'number,title,body,labels')
      stdout, _, status = run_gh(
        'issue', 'view', issue_number.to_s,
        '--json', fields
      )
      return nil unless status.success?

      JSON.parse(stdout)
    rescue JSON::ParserError => e
      @logger&.warn("Failed to parse issue view JSON: #{e.message}")
      nil
    end

    private

    def in_progress?(issue)
      issue['labels']&.any? { |l| l['name'] == @config.label_in_progress }
    end

    def authorized_issue?(issue)
      authors = allowed_authors
      author_login = issue.dig('author', 'login')

      if authors.empty?
        return check_comment_requirement(issue) if author_login == current_user
      elsif authors.include?(author_login)
        return check_comment_requirement(issue)
      end

      @logger&.warn("Skipping issue ##{issue['number']}: author '#{author_login}' not in allowed list")
      false
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
      stdout, _, status = run_gh(
        'issue', 'view', issue_number.to_s,
        '--json', 'comments'
      )
      return [] unless status.success?

      JSON.parse(stdout).fetch('comments', [])
    rescue JSON::ParserError => e
      @logger&.warn("Failed to parse issue comments JSON: #{e.message}")
      []
    end

    def allowed_authors
      @config.allowed_authors
    end

    def current_user
      return @current_user if defined?(@current_user_resolved)

      stdout, _, status = Open3.capture3('gh', 'api', 'user', '--jq', '.login')
      if status.success?
        @current_user = stdout.strip
        @current_user_resolved = true
        @current_user
      else
        @logger&.warn("Could not determine current user via 'gh api user'")
        nil
      end
    end

    def run_gh(*)
      Open3.capture3('gh', *, chdir: @config.project_dir)
    end
  end
end
