# frozen_string_literal: true

require 'open3'

module Ocak
  # Factory methods for building logger, claude, merge manager instances, plus setup helpers.
  # Extracted from PipelineRunner to reduce file size.
  module InstanceBuilders
    private

    def build_logger(issue_number: nil)
      PipelineLogger.new(log_dir: File.join(@config.project_dir, @config.log_dir),
                         issue_number: issue_number, log_level: @options.fetch(:log_level, :normal))
    end

    def build_claude(logger)
      ClaudeRunner.new(config: @config, logger: logger, watch: @watch_formatter, registry: @registry)
    end

    def build_merge_manager(logger:, issues:)
      if issues.is_a?(LocalIssueFetcher) && !gh_available?
        LocalMergeManager.new(config: @config, logger: logger, issues: issues)
      else
        MergeManager.new(config: @config, claude: build_claude(logger), logger: logger,
                         issues: issues, watch: @watch_formatter)
      end
    end

    def gh_available?
      _, _, status = Open3.capture3('gh', 'repo', 'view', '--json', 'name', chdir: @config.project_dir)
      status.success?
    rescue Errno::ENOENT
      false
    end

    def cleanup_stale_worktrees(logger)
      worktrees = WorktreeManager.new(config: @config, logger: logger)
      removed = worktrees.clean_stale
      removed.each { |path| logger.info("Cleaned stale worktree: #{path}") }
    rescue StandardError => e
      logger.warn("Stale worktree cleanup failed: #{e.message}")
    end

    def ensure_labels(issues, logger)
      issues.ensure_labels(@config.all_labels)
    rescue StandardError => e
      logger.warn("Failed to ensure labels: #{e.message}")
    end
  end
end
