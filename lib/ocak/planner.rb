# frozen_string_literal: true

require 'json'

module Ocak
  # Batch planning logic extracted from PipelineRunner.
  module Planner
    STEP_PROMPTS = {
      'implement' => 'Implement GitHub issue #%<issue>s',
      'review' => 'Review the changes for GitHub issue #%<issue>s. Run: git diff main',
      'verify' => 'Review the changes for GitHub issue #%<issue>s. Run: git diff main',
      'security' => 'Security review changes for GitHub issue #%<issue>s. Run: git diff main',
      'document' => 'Add documentation for changes in GitHub issue #%<issue>s',
      'merge' => 'Create a PR, merge it, and close issue #%<issue>s'
    }.freeze

    ISSUE_CONTEXT_ROLES = %w[implement document merge].freeze

    def build_step_prompt(role, issue_number, review_output, issue_data: nil)
      prompt = if role == 'fix'
                 "Fix these review findings for issue ##{issue_number}:\n\n" \
                   "<review_output>\n#{review_output}\n</review_output>"
               elsif STEP_PROMPTS.key?(role)
                 format(STEP_PROMPTS[role], issue: issue_number)
               else
                 "Run #{role} for GitHub issue ##{issue_number}"
               end

      prompt += format_issue_context(issue_data) if issue_data && ISSUE_CONTEXT_ROLES.include?(role)
      prompt
    end

    def format_issue_context(issue_data)
      parts = []
      parts << "Title: #{issue_data['title']}" if issue_data['title']
      parts << issue_data['body'] if issue_data['body']
      "\n\n<issue_data>\n#{parts.join("\n\n")}\n</issue_data>"
    end

    def plan_batches(issues, logger:, claude:)
      return sequential_batches(issues) if issues.size <= 1
      return plan_multi_repo_batches(issues) if @config&.multi_repo?

      issue_json = JSON.generate(issues.map { |i| { number: i['number'], title: i['title'] } })
      result = claude.run_agent(
        'planner',
        "Analyze these issues and output parallelization batches as JSON:\n\n<issue_data>\n#{issue_json}\n</issue_data>"
      )

      unless result.success?
        logger.warn('Planner failed, falling back to sequential')
        return sequential_batches(issues)
      end

      parse_planner_output(result.output, issues, logger)
    end

    def plan_multi_repo_batches(issues)
      by_repo = issues.group_by { |i| i['_target']&.dig(:name) || '__self__' }

      # If all issues target different repos, one big parallel batch — no agent call needed
      return [{ 'batch' => 1, 'issues' => issues }] if by_repo.values.all? { |group| group.size == 1 }

      # Otherwise, issues in the same repo are sequential (by depth), cross-repo are parallel
      max_depth = by_repo.values.map(&:size).max
      (0...max_depth).map do |depth|
        batch_issues = by_repo.values.filter_map { |group| group[depth] }
        { 'batch' => depth + 1, 'issues' => batch_issues }
      end
    end

    def parse_planner_output(output, issues, logger)
      json_match = output.match(/\{[\s\S]*"batches"[\s\S]*\}/)
      if json_match
        parsed = JSON.parse(json_match[0])
        batches = parsed['batches']
        return sequential_batches(issues) unless batches.is_a?(Array)

        batches
      else
        logger.warn('Could not parse planner output, falling back to sequential')
        sequential_batches(issues)
      end
    rescue JSON::ParserError => e
      logger.warn("JSON parse error from planner: #{e.message}")
      sequential_batches(issues)
    end

    def sequential_batches(issues)
      issues.map.with_index do |i, idx|
        issue = i.dup
        issue['complexity'] ||= 'full'
        { 'batch' => idx + 1, 'issues' => [issue] }
      end
    end
  end
end
