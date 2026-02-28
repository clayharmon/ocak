# frozen_string_literal: true

require 'yaml'

module Ocak
  class Config
    CONFIG_FILE = 'ocak.yml'

    attr_reader :project_dir

    def self.load(dir = Dir.pwd)
      path = File.join(dir, CONFIG_FILE)
      raise ConfigNotFound, "No ocak.yml found in #{dir}. Run `ocak init` first." unless File.exist?(path)

      new(YAML.safe_load_file(path, symbolize_names: true), dir)
    end

    def initialize(data, project_dir = Dir.pwd)
      @data = data || {}
      @project_dir = project_dir
      @overrides = {}
      validate!
    end

    def override(key, value)
      @overrides[key] = value
    end

    # Stack
    def language      = dig(:stack, :language) || 'unknown'
    def framework     = dig(:stack, :framework)
    def test_command   = dig(:stack, :test_command)
    def lint_command   = dig(:stack, :lint_command)
    def format_command = dig(:stack, :format_command)
    def setup_command  = dig(:stack, :setup_command)

    # Returns the lint command with auto-fix flags stripped, suitable for check-only verification.
    def lint_check_command
      cmd = lint_command
      return nil unless cmd

      cmd.gsub(/\s+(?:-A|--fix|--write|--allow-dirty)\b/, '').strip
    end

    def security_commands
      dig(:stack, :security_commands) || []
    end

    # Pipeline
    def max_parallel  = @overrides[:max_parallel] || dig(:pipeline, :max_parallel) || 5
    def poll_interval = @overrides[:poll_interval] || dig(:pipeline, :poll_interval) || 60
    def worktree_dir  = dig(:pipeline, :worktree_dir) || '.claude/worktrees'
    def log_dir       = dig(:pipeline, :log_dir) || 'logs/pipeline'
    def cost_budget   = dig(:pipeline, :cost_budget)
    def manual_review = @overrides[:manual_review] || dig(:pipeline, :manual_review) || false

    # Safety
    def allowed_authors    = dig(:safety, :allowed_authors) || []
    def require_comment    = dig(:safety, :require_comment)
    def max_issues_per_run = dig(:safety, :max_issues_per_run) || 5

    # Labels
    def label_ready = dig(:labels, :ready) || 'auto-ready'
    def label_in_progress = dig(:labels, :in_progress) || 'auto-doing'
    def label_completed  = dig(:labels, :completed) || 'completed'
    def label_failed     = dig(:labels, :failed) || 'pipeline-failed'
    def label_reready         = dig(:labels, :reready) || 'auto-reready'
    def label_awaiting_review = dig(:labels, :awaiting_review) || 'auto-pending-human'

    def all_labels
      [label_ready, label_in_progress, label_completed, label_failed, label_reready, label_awaiting_review]
    end

    # Steps
    def steps
      @data[:steps] || default_steps
    end

    # Agent paths
    def agent_path(name)
      custom = dig(:agents, name.to_sym)
      return File.join(@project_dir, custom) if custom

      File.join(@project_dir, '.claude', 'agents', "#{name.to_s.tr('_', '-')}.md")
    end

    private

    def dig(*keys)
      keys.reduce(@data) { |h, k| h.is_a?(Hash) ? h[k] : nil }
    end

    def validate!
      return if @data.is_a?(Hash)

      raise ConfigError, 'ocak.yml must be a YAML hash'
    end

    def default_steps
      [
        { agent: 'implementer', role: 'implement' },
        { agent: 'reviewer', role: 'review' },
        { agent: 'implementer', role: 'fix', condition: 'has_findings' },
        { agent: 'reviewer', role: 'verify', condition: 'had_fixes' },
        { agent: 'security-reviewer', role: 'security' },
        { agent: 'implementer', role: 'fix', condition: 'has_findings', complexity: 'full' },
        { agent: 'documenter', role: 'document', complexity: 'full' },
        { agent: 'auditor', role: 'audit', complexity: 'full' },
        { agent: 'merger', role: 'merge' }
      ]
    end

    class ConfigNotFound < StandardError; end
    class ConfigError < StandardError; end
  end
end
