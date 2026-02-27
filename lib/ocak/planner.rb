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
      'audit' => 'Audit the changed files for issue #%<issue>s. Run: git diff main --name-only',
      'merge' => 'Create a PR, merge it, and close issue #%<issue>s',
      'create_pr' => 'Create a PR, merge it, and close issue #%<issue>s'
    }.freeze

    def build_step_prompt(role, issue_number, review_output)
      if role == 'fix'
        "Fix these review findings for issue ##{issue_number}:\n\n#{review_output}"
      elsif STEP_PROMPTS.key?(role)
        format(STEP_PROMPTS[role], issue: issue_number)
      else
        "Run #{role} for GitHub issue ##{issue_number}"
      end
    end

    def plan_batches(issues, logger:, claude:)
      return sequential_batches(issues) if issues.size <= 1

      issue_json = JSON.generate(issues.map { |i| { number: i['number'], title: i['title'] } })
      result = claude.run_agent(
        'planner',
        "Analyze these issues and output parallelization batches as JSON:\n\n#{issue_json}"
      )

      unless result.success?
        logger.warn('Planner failed, falling back to sequential')
        return sequential_batches(issues)
      end

      parse_planner_output(result.output, issues, logger)
    end

    def parse_planner_output(output, issues, logger)
      json_match = output.match(/\{[\s\S]*"batches"[\s\S]*\}/)
      if json_match
        parsed = JSON.parse(json_match[0])
        parsed['batches']
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
