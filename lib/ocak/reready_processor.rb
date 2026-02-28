# frozen_string_literal: true

require 'open3'
require 'shellwords'
require_relative 'git_utils'

module Ocak
  class RereadyProcessor
    def initialize(config:, logger:, claude:, issues:, watch: nil)
      @config = config
      @logger = logger
      @claude = claude
      @issues = issues
      @watch = watch
    end

    # Main entry point. Returns true on success.
    def process(pull_request)
      pr_number = pull_request['number']
      issue_number = @issues.extract_issue_number_from_pr(pull_request)
      unless issue_number
        @logger.warn("PR ##{pr_number}: could not extract issue number from body")
        return false
      end

      feedback = gather_feedback(pr_number, issue_number)
      return false unless feedback

      branch_name = pull_request['headRefName']
      unless GitUtils.safe_branch_name?(branch_name)
        @logger.error("PR ##{pr_number}: unsafe branch name '#{branch_name}'")
        return false
      end

      unless checkout_pr_branch(branch_name)
        @logger.error("PR ##{pr_number}: failed to checkout branch #{branch_name}")
        cleanup
        return false
      end

      success = run_feedback_loop(feedback)
      handle_result(pr_number, success)
    ensure
      cleanup
    end

    private

    def gather_feedback(pr_number, issue_number)
      comments_data = @issues.fetch_pr_comments(pr_number)
      issue_data = fetch_issue(issue_number)
      return nil unless issue_data

      { pr_number: pr_number, issue_number: issue_number,
        comments: comments_data[:comments], reviews: comments_data[:reviews],
        issue_title: issue_data['title'], issue_body: issue_data['body'] }
    end

    def fetch_issue(issue_number)
      @issues.view(issue_number, fields: 'title,body')
    end

    def checkout_pr_branch(branch_name)
      _, _, fetch_status = Open3.capture3('git', 'fetch', 'origin', branch_name,
                                          chdir: @config.project_dir)
      return false unless fetch_status.success?

      _, _, checkout_status = Open3.capture3('git', 'checkout', branch_name,
                                             chdir: @config.project_dir)
      return false unless checkout_status.success?

      _, _, pull_status = Open3.capture3('git', 'pull', '--rebase', 'origin', branch_name,
                                         chdir: @config.project_dir)
      pull_status.success?
    end

    def run_feedback_loop(feedback)
      prompt = build_feedback_prompt(feedback)
      result = @claude.run_agent('implementer', prompt, chdir: @config.project_dir)
      return false unless result.success?

      verified = run_verification
      return true if verified

      # One retry
      retry_result = @claude.run_agent('implementer', "Fix the failing tests and lint errors.\n#{prompt}",
                                       chdir: @config.project_dir)
      return false unless retry_result.success?

      run_verification
    end

    def run_verification
      test_ok = run_optional_cmd(@config.test_command)
      lint_ok = run_optional_cmd(@config.lint_check_command)
      test_ok && lint_ok
    end

    def run_optional_cmd(cmd)
      return true if cmd.nil? || cmd.empty?

      _, _, status = Open3.capture3(*Shellwords.shellsplit(cmd), chdir: @config.project_dir)
      status.success?
    end

    def handle_result(pr_number, success)
      if success
        push_ok = push_updates
        @issues.pr_transition(pr_number, remove_label: @config.label_reready)
        if push_ok
          @issues.pr_comment(pr_number, 'Feedback addressed. Please re-review.')
        else
          @issues.pr_comment(pr_number, 'Failed to push feedback changes. Please check logs.')
        end
        push_ok
      else
        @issues.pr_transition(pr_number, remove_label: @config.label_reready)
        @issues.pr_comment(pr_number, 'Failed to address feedback automatically. Please check logs.')
        false
      end
    end

    def push_updates
      committed = GitUtils.commit_changes(
        chdir: @config.project_dir,
        message: 'fix: address review feedback',
        logger: @logger
      )
      @logger.warn('Proceeding to push without new commit') unless committed

      _, _, push_status = Open3.capture3('git', 'push', '--force-with-lease', chdir: @config.project_dir)
      push_status.success?
    end

    def cleanup
      GitUtils.checkout_main(chdir: @config.project_dir, logger: @logger)
    end

    def build_feedback_prompt(feedback)
      reviews_text = Array(feedback[:reviews]).map do |r|
        "- #{r.dig('author', 'login')} [#{r['state']}]: #{r['body']}"
      end.join("\n")

      comments_text = Array(feedback[:comments]).map do |c|
        "- #{c.dig('author', 'login')}: #{c['body']}"
      end.join("\n")

      <<~PROMPT
        Address the review feedback on PR ##{feedback[:pr_number]} for issue ##{feedback[:issue_number]}.

        ## Original Issue: #{feedback[:issue_title]}
        <issue_body>
        #{feedback[:issue_body]}
        </issue_body>

        ## Review Comments
        <review_comments>
        #{reviews_text.empty? ? '(none)' : reviews_text}
        </review_comments>

        ## PR Comments
        <pr_comments>
        #{comments_text.empty? ? '(none)' : comments_text}
        </pr_comments>

        ## Instructions
        Read the PR diff with `git diff main` to understand current changes.
        Address each piece of feedback. Do NOT revert changes unless explicitly requested.
        Run tests and lint after making changes.
      PROMPT
    end
  end
end
