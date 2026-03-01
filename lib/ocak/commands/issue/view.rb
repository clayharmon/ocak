# frozen_string_literal: true

require_relative '../../config'
require_relative '../../local_issue_fetcher'

module Ocak
  module Commands
    module Issue
      class View < Dry::CLI::Command
        desc 'View a local issue'

        argument :issue, type: :integer, required: true, desc: 'Issue number'

        def call(issue:, **)
          config = Config.load
          fetcher = LocalIssueFetcher.new(config: config)
          data = fetcher.view(issue.to_i)

          unless data
            warn "Issue ##{issue} not found."
            exit 1
          end

          labels = (data['labels'] || []).map { |l| l['name'] }.join(', ')
          puts "##{data['number']}  #{data['title']}"
          puts "Labels: #{labels}" unless labels.empty?
          puts "Complexity: #{data['complexity']}" if data['complexity'] && data['complexity'] != 'full'
          puts ''
          puts data['body'] unless data['body'].to_s.empty?

          # Show pipeline comments from the raw file
          path = File.join('.ocak', 'issues', format('%04d.md', issue.to_i))
          show_pipeline_comments(path)
        rescue Config::ConfigNotFound => e
          warn "Error: #{e.message}"
          exit 1
        end

        private

        def show_pipeline_comments(path)
          return unless File.exist?(path)

          content = File.read(path)
          sentinel = LocalIssueFetcher::COMMENTS_SENTINEL
          return unless content.include?(sentinel)

          comments = content.split(sentinel, 2).last.to_s.strip
          return if comments.empty?

          puts ''
          puts '--- Pipeline Activity ---'
          puts comments
        end
      end
    end
  end
end
