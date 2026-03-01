# frozen_string_literal: true

require 'yaml'
require 'fileutils'
require 'time'
require_relative 'issue_fetcher'

module Ocak
  class LocalIssueFetcher < IssueFetcher
    COMMENTS_SENTINEL = '<!-- pipeline-comments -->'

    def initialize(config:, logger: nil)
      super
      @store_dir = File.join(config.project_dir, '.ocak', 'issues')
    end

    # --- Issue operations (overrides) ---

    def fetch_ready
      all_issues.select do |issue|
        labels = label_names(issue)
        labels.include?(@config.label_ready) && !labels.include?(@config.label_in_progress)
      end
    rescue StandardError => e
      @logger&.warn("LocalIssueFetcher#fetch_ready failed: #{e.message}")
      []
    end

    def view(issue_number, fields: 'number,title,body,labels') # rubocop:disable Lint/UnusedMethodArgument
      read_issue(issue_number.to_i)
    rescue StandardError => e
      @logger&.warn("LocalIssueFetcher#view failed for ##{issue_number}: #{e.message}")
      nil
    end

    def add_label(issue_number, label)
      update_frontmatter(issue_number.to_i) do |fm|
        fm['labels'] = ((fm['labels'] || []) | [label])
      end
    end

    def remove_label(issue_number, label)
      update_frontmatter(issue_number.to_i) do |fm|
        fm['labels'] = (fm['labels'] || []) - [label]
      end
    end

    def comment(issue_number, body)
      path = issue_path(issue_number.to_i)
      return unless path && File.exist?(path)

      content = File.read(path)
      timestamp = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')

      unless content.include?(COMMENTS_SENTINEL)
        File.write(path, "#{content.chomp}\n\n#{COMMENTS_SENTINEL}\n#{timestamp} — #{body}\n")
        return
      end

      File.open(path, 'a') { |f| f.write("#{timestamp} — #{body}\n") }
    rescue StandardError => e
      @logger&.warn("LocalIssueFetcher#comment failed for ##{issue_number}: #{e.message}")
      nil
    end

    def ensure_label(_label) = nil
    def ensure_labels(_labels) = nil

    # --- Issue creation (CLI only) ---

    def create(title:, body: '', labels: [], complexity: 'full')
      FileUtils.mkdir_p(@store_dir)
      number = next_issue_number
      fm = {
        'number' => number,
        'title' => title,
        'labels' => labels,
        'complexity' => complexity,
        'created_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
      }
      File.write(issue_path(number), build_file(fm, body))
      number
    end

    # --- Queries ---

    def all_issues
      return [] unless Dir.exist?(@store_dir)

      Dir.glob(File.join(@store_dir, '*.md'))
         .filter_map { |f| parse_issue_file(f) }
    end

    private

    def read_issue(issue_number)
      path = issue_path(issue_number)
      return nil unless File.exist?(path)

      parse_issue_file(path)
    end

    def parse_issue_file(path)
      content = File.read(path)
      parts = content.split(/^---\s*$/, 3)
      return nil unless parts.size >= 3

      fm = YAML.safe_load(parts[1]) || {}
      raw_body = parts[2]
      body = raw_body.split(COMMENTS_SENTINEL, 2).first.to_s.strip

      {
        'number' => fm['number'],
        'title' => fm['title'],
        'body' => body,
        'labels' => (fm['labels'] || []).map { |l| { 'name' => l } },
        'author' => { 'login' => 'local' },
        'complexity' => fm['complexity'] || 'full'
      }
    rescue StandardError => e
      @logger&.warn("Failed to parse issue file #{path}: #{e.message}")
      nil
    end

    def update_frontmatter(issue_number)
      path = issue_path(issue_number)
      return unless File.exist?(path)

      content = File.read(path)
      parts = content.split(/^---\s*$/, 3)
      return unless parts.size >= 3

      fm = YAML.safe_load(parts[1]) || {}
      yield fm

      File.write(path, "---\n#{YAML.dump(fm)}---\n#{parts[2]}")
    rescue StandardError => e
      @logger&.warn("LocalIssueFetcher#update_frontmatter failed for ##{issue_number}: #{e.message}")
      nil
    end

    def issue_path(number)
      File.join(@store_dir, format('%04d.md', number))
    end

    def next_issue_number
      existing = Dir.glob(File.join(@store_dir, '*.md'))
                    .filter_map { |f| File.basename(f, '.md').to_i }
      existing.empty? ? 1 : existing.max + 1
    end

    def label_names(issue)
      (issue['labels'] || []).map { |l| l['name'] }
    end

    def build_file(frontmatter, body)
      "---\n#{YAML.dump(frontmatter)}---\n\n#{body}\n"
    end
  end
end
