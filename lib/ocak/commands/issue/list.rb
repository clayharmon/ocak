# frozen_string_literal: true

require_relative '../../config'
require_relative '../../local_issue_fetcher'

module Ocak
  module Commands
    module Issue
      class List < Dry::CLI::Command
        desc 'List local issues'

        option :label, type: :string, desc: 'Filter by label'

        def call(**options)
          config = Config.load
          fetcher = LocalIssueFetcher.new(config: config)
          issues = fetcher.all_issues

          if options[:label]
            issues = issues.select do |i|
              i['labels']&.any? { |l| l['name'] == options[:label] }
            end
          end

          if issues.empty?
            puts 'No issues found.'
            return
          end

          issues.sort_by { |i| i['number'] }.each do |issue|
            labels = (issue['labels'] || []).map { |l| l['name'] }.join(', ')
            label_str = labels.empty? ? '' : "  [#{labels}]"
            puts format('#%-4<num>d %<title>s%<labels>s',
                        num: issue['number'], title: issue['title'], labels: label_str)
          end
        rescue Config::ConfigNotFound => e
          warn "Error: #{e.message}"
          exit 1
        end
      end
    end
  end
end
