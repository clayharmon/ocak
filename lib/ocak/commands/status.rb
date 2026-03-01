# frozen_string_literal: true

require 'open3'
require 'json'
require_relative '../config'
require_relative '../issue_backend'
require_relative '../run_report'
require_relative '../worktree_manager'

module Ocak
  module Commands
    class Status < Dry::CLI::Command
      desc 'Show pipeline status'

      option :report, type: :boolean, default: false, desc: 'Show run reports'

      def call(**options)
        config = Config.load

        if options[:report]
          show_reports(config)
        else
          show_default_status(config)
        end
      rescue Config::ConfigNotFound => e
        warn "Error: #{e.message}"
        exit 1
      end

      private

      def show_default_status(config)
        puts 'Pipeline Status'
        puts '=' * 40
        puts ''

        show_issues(config)
        puts ''
        show_worktrees(config)
        puts ''
        show_recent_logs(config)
      end

      def show_issues(config)
        puts 'Issues:'
        fetcher = IssueBackend.build(config: config)

        if fetcher.is_a?(LocalIssueFetcher)
          show_local_issues(fetcher, config)
        else
          show_github_issues(config)
        end
      end

      def show_local_issues(fetcher, config)
        all = fetcher.all_issues
        %w[ready in_progress completed failed].each do |state|
          label = config.send(:"label_#{state}")
          count = all.count { |i| i['labels']&.any? { |l| l['name'] == label } }
          icon = { 'ready' => '  ', 'in_progress' => '  ', 'completed' => '  ', 'failed' => '  ' }[state]
          puts "  #{icon} #{state.tr('_', ' ')}: #{count} (label: #{label})"
        end
      end

      def show_github_issues(config)
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

      def show_reports(config)
        reports = RunReport.load_all(project_dir: config.project_dir)

        if reports.empty?
          puts 'No run reports found.'
          return
        end

        sorted = reports.sort_by { |r| r[:started_at].to_s }.reverse
        show_recent_runs(sorted)
        puts ''
        show_aggregates(sorted)
      end

      def show_recent_runs(reports)
        puts 'Recent Runs (last 10):'
        reports.first(10).each do |r|
          icon = r[:success] ? "\u2705" : "\u274C"
          steps_str = step_count_str(r)
          date = format_report_date(r[:started_at])
          failed = r[:success] ? '' : "  (failed: #{r[:failed_phase]})"
          cost = format('$%.2f', r[:total_cost_usd].to_f)
          puts "  ##{r[:issue_number]}  #{icon}  #{r[:total_duration_s]}s  #{cost}  #{steps_str}  #{date}#{failed}"
        end
      end

      def show_aggregates(reports)
        recent = reports.first(20)
        puts "Aggregates (last #{recent.size} runs):"

        avg_cost = recent.sum { |r| r[:total_cost_usd].to_f } / recent.size
        avg_duration = recent.sum { |r| r[:total_duration_s].to_i } / recent.size
        success_count = recent.count { |r| r[:success] }
        success_rate = (success_count.to_f / recent.size * 100).round

        puts "  Avg cost:      $#{format('%.2f', avg_cost)}"
        puts "  Avg duration:  #{avg_duration}s"
        puts "  Success rate:  #{success_rate}%"

        show_slowest_step(recent)
        show_most_skipped(recent)
      end

      def show_slowest_step(reports)
        durations, costs = collect_step_metrics(reports)
        return if durations.empty?

        name, dur_values = durations.max_by { |_, vals| vals.sum.to_f / vals.size }
        avg_dur = (dur_values.sum.to_f / dur_values.size).round
        avg_cost = costs[name].sum / costs[name].size
        puts "  Slowest step:  #{name} (avg #{avg_dur}s, $#{format('%.2f', avg_cost)})"
      end

      def collect_step_metrics(reports)
        durations = Hash.new { |h, k| h[k] = [] }
        costs = Hash.new { |h, k| h[k] = [] }

        reports.each do |r|
          (r[:steps] || []).each do |s|
            next unless s[:status] == 'completed'

            durations[s[:role]] << s[:duration_s].to_i
            costs[s[:role]] << s[:cost_usd].to_f
          end
        end

        [durations, costs]
      end

      def show_most_skipped(reports)
        skip_counts = Hash.new(0)
        total_counts = Hash.new(0)

        reports.each do |r|
          (r[:steps] || []).each do |s|
            total_counts[s[:role]] += 1
            skip_counts[s[:role]] += 1 if s[:status] == 'skipped'
          end
        end

        skipped_roles = skip_counts.select { |_, count| count.positive? }
        return if skipped_roles.empty?

        most = skipped_roles.max_by { |role, count| count.to_f / total_counts[role] }
        name = most[0]
        rate = (most[1].to_f / total_counts[name] * 100).round
        puts "  Most skipped:  #{name} (#{rate}% skip rate)"
      end

      def step_count_str(report)
        steps = report[:steps] || []
        completed = steps.count { |s| s[:status] == 'completed' }
        "#{completed}/#{steps.size} steps"
      end

      def format_report_date(iso_str)
        return 'unknown' unless iso_str

        Time.parse(iso_str).strftime('%Y-%m-%d %H:%M')
      rescue ArgumentError
        iso_str.to_s[0..15]
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
      rescue JSON::ParserError, Errno::ENOENT
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
