# frozen_string_literal: true

require 'open3'
require 'json'
require_relative '../config'
require_relative '../worktree_manager'

module Ocak
  module Commands
    class Status < Dry::CLI::Command
      desc 'Show pipeline status'

      def call(**)
        config = Config.load

        puts 'Pipeline Status'
        puts '=' * 40
        puts ''

        show_issues(config)
        puts ''
        show_worktrees(config)
        puts ''
        show_recent_logs(config)
      rescue Config::ConfigNotFound => e
        warn "Error: #{e.message}"
        exit 1
      end

      private

      def show_issues(config)
        puts 'Issues:'

        %w[ready in_progress completed failed].each do |state|
          label = config.send(:"label_#{state}")
          count = fetch_issue_count(label, config)
          icon = { 'ready' => '  ', 'in_progress' => '  ', 'completed' => '  ', 'failed' => '  ' }[state]
          puts "  #{icon} #{state.tr('_', ' ')}: #{count} (label: #{label})"
        end
      end

      def show_worktrees(config)
        puts 'Worktrees:'
        manager = WorktreeManager.new(config: config)
        worktrees = manager.list

        pipeline_wts = worktrees.select { |wt| wt[:branch]&.start_with?('auto/') }
        if pipeline_wts.empty?
          puts '  No active pipeline worktrees'
        else
          pipeline_wts.each do |wt|
            puts "  #{wt[:branch]} -> #{wt[:path]}"
          end
        end
      end

      def show_recent_logs(config)
        log_dir = File.join(config.project_dir, config.log_dir)
        return unless Dir.exist?(log_dir)

        puts 'Recent logs:'
        logs = Dir.glob(File.join(log_dir, '*.log')).last(5)
        if logs.empty?
          puts '  No logs yet'
        else
          logs.reverse_each do |log|
            name = File.basename(log)
            size = File.size(log)
            puts "  #{name} (#{format_size(size)})"
          end
        end
      end

      def fetch_issue_count(label, config)
        stdout, _, status = Open3.capture3(
          'gh', 'issue', 'list',
          '--label', label,
          '--state', 'open',
          '--json', 'number',
          '--limit', '100',
          chdir: config.project_dir
        )
        return 0 unless status.success?

        JSON.parse(stdout).size
      rescue StandardError
        0
      end

      def format_size(bytes)
        if bytes < 1024
          "#{bytes}B"
        elsif bytes < 1024 * 1024
          "#{(bytes / 1024.0).round(1)}KB"
        else
          "#{(bytes / (1024.0 * 1024)).round(1)}MB"
        end
      end
    end
  end
end
