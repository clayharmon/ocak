# frozen_string_literal: true

require 'yaml'

module Ocak
  class Config
    CONFIG_FILE = 'ocak.yml'

    attr_reader :data, :project_dir

    def self.load(dir = Dir.pwd)
      path = File.join(dir, CONFIG_FILE)
      raise ConfigNotFound, "No ocak.yml found in #{dir}. Run `ocak init` first." unless File.exist?(path)

      new(YAML.safe_load_file(path, symbolize_names: true), dir)
    end

    def initialize(data, project_dir = Dir.pwd)
      @data = data || {}
      @project_dir = project_dir
      validate!
    end

    # Stack
    def language      = dig(:stack, :language) || 'unknown'
    def framework     = dig(:stack, :framework)
    def test_command   = dig(:stack, :test_command)
    def lint_command   = dig(:stack, :lint_command)
    def format_command = dig(:stack, :format_command)

    def security_commands
      dig(:stack, :security_commands) || []
    end

    # Pipeline
    def max_parallel  = dig(:pipeline, :max_parallel) || 3
    def poll_interval = dig(:pipeline, :poll_interval) || 60
    def worktree_dir  = dig(:pipeline, :worktree_dir) || '.claude/worktrees'
    def log_dir       = dig(:pipeline, :log_dir) || 'logs/pipeline'

    # Labels
    def label_ready = dig(:labels, :ready) || 'auto-ready'
    def label_in_progress = dig(:labels, :in_progress) || 'in-progress'
    def label_completed  = dig(:labels, :completed) || 'completed'
    def label_failed     = dig(:labels, :failed) || 'pipeline-failed'

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
        { agent: 'security_reviewer', role: 'security' },
        { agent: 'implementer', role: 'fix', condition: 'has_findings' },
        { agent: 'documenter', role: 'document' },
        { agent: 'auditor', role: 'audit' },
        { agent: 'merger', role: 'merge' }
      ]
    end

    class ConfigNotFound < StandardError; end
    class ConfigError < StandardError; end
  end
end
