# frozen_string_literal: true

require_relative '../../config'
require_relative '../../local_issue_fetcher'

module Ocak
  module Commands
    module Issue
      class Close < Dry::CLI::Command
        desc 'Close a local issue (sets completed label)'

        argument :issue, type: :integer, required: true, desc: 'Issue number'

        def call(issue:, **)
          config = Config.load
          fetcher = LocalIssueFetcher.new(config: config)
          issue_number = issue.to_i

          data = fetcher.view(issue_number)
          unless data
            warn "Issue ##{issue} not found."
            exit 1
          end

          fetcher.remove_label(issue_number, config.label_ready)
          fetcher.remove_label(issue_number, config.label_in_progress)
          fetcher.add_label(issue_number, config.label_completed)

          puts "Closed issue ##{issue_number}: #{data['title']}"
        rescue Config::ConfigNotFound => e
          warn "Error: #{e.message}"
          exit 1
        end
      end
    end
  end
end
