# frozen_string_literal: true

require 'fileutils'
require_relative '../config'
require_relative '../worktree_manager'

module Ocak
  module Commands
    class Clean < Dry::CLI::Command
      desc 'Remove stale worktrees, logs, and reports'

      option :logs, type: :boolean, default: false, desc: 'Clean log files, state files, and reports'
      option :all, type: :boolean, default: false, desc: 'Clean worktrees and logs'
      option :keep, type: :integer, desc: 'Only remove artifacts older than N days'

      def call(**options)
        config = Config.load
        do_worktrees = !options[:logs] || options[:all]
        do_logs = options[:logs] || options[:all]

        clean_worktrees(config) if do_worktrees
        clean_logs(config, keep_days: options[:keep]) if do_logs
      rescue Config::ConfigNotFound => e
        warn "Error: #{e.message}"
        exit 1
      end

      private

      def clean_worktrees(config)
        manager = WorktreeManager.new(config: config)
        puts 'Cleaning stale worktrees...'
        removed = manager.clean_stale

        if removed.empty?
          puts 'No stale worktrees found.'
        else
          removed.each { |path| puts "  Removed: #{path}" }
          puts "Cleaned #{removed.size} worktree(s)."
        end
      end

      def clean_logs(config, keep_days:)
        cutoff = keep_days ? Time.now - (keep_days * 86_400) : nil
        puts keep_days ? "Cleaning logs older than #{keep_days} days..." : 'Cleaning logs...'

        log_dir = File.join(config.project_dir, config.log_dir)
        reports_dir = File.join(config.project_dir, '.ocak', 'reports')

        artifacts = collect_artifacts(log_dir, reports_dir)
        removed = remove_artifacts(artifacts, cutoff)

        if removed.empty?
          puts 'No artifacts to clean.'
        else
          puts "Cleaned #{removed.size} artifact(s)."
        end
      end

      def collect_artifacts(log_dir, reports_dir)
        artifacts = []

        if Dir.exist?(log_dir)
          artifacts += Dir.glob(File.join(log_dir, '*.log'))
          artifacts += Dir.glob(File.join(log_dir, 'issue-*-state.json'))
          artifacts += Dir.glob(File.join(log_dir, 'issue-*/')).select { |f| File.directory?(f) }
        end

        artifacts += Dir.glob(File.join(reports_dir, '*.json')) if Dir.exist?(reports_dir)

        artifacts
      end

      def remove_artifacts(artifacts, cutoff)
        removed = []
        artifacts.each do |path|
          next if cutoff && File.mtime(path) >= cutoff

          if File.directory?(path)
            FileUtils.rm_rf(path)
          else
            FileUtils.rm_f(path)
          end
          puts "  Removed: #{path}"
          removed << path
        end
        removed
      end
    end
  end
end
