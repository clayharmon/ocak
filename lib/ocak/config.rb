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

    # Returns the lint command suitable for check-only verification.
    # Uses explicit lint_check_command config if provided; otherwise strips known fix flags from lint_command.
    def lint_check_command
      explicit = dig(:stack, :lint_check_command)
      return explicit if explicit

      cmd = lint_command
      return nil unless cmd

      cmd.gsub(/\s+(?:-A|--fix-dry-run|--fix-type|--unsafe-fix|--fix|--write|--allow-dirty)\b/, '').strip
    end

    def security_commands
      dig(:stack, :security_commands) || []
    end

    # Pipeline
    def max_parallel  = @overrides[:max_parallel] || dig(:pipeline, :max_parallel) || 5
    def poll_interval = @overrides[:poll_interval] || dig(:pipeline, :poll_interval) || 60

    def worktree_dir
      validate_path(dig(:pipeline, :worktree_dir) || '.claude/worktrees')
    end

    def log_dir
      validate_path(dig(:pipeline, :log_dir) || 'logs/pipeline')
    end

    def cost_budget   = dig(:pipeline, :cost_budget)
    def manual_review = @overrides[:manual_review] || dig(:pipeline, :manual_review) || false
    def audit_mode    = @overrides[:audit_mode] || dig(:pipeline, :audit_mode) || false

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
      return File.join(@project_dir, validate_path(custom)) if custom

      File.join(@project_dir, '.claude', 'agents', "#{name.to_s.tr('_', '-')}.md")
    end

    private

    def validate_path(relative)
      expanded = File.expand_path(File.join(@project_dir, relative))
      return relative if expanded.start_with?("#{@project_dir}/") || expanded == @project_dir

      raise ConfigError, "Path '#{relative}' escapes project directory"
    end

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
        { agent: 'security-reviewer', role: 'security', complexity: 'full' },
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
