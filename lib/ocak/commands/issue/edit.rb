# frozen_string_literal: true

require_relative '../../config'

module Ocak
  module Commands
    module Issue
      class Edit < Dry::CLI::Command
        desc 'Edit a local issue in $EDITOR'

        argument :issue, type: :integer, required: true, desc: 'Issue number'

        def call(issue:, **)
          config = Config.load
          path = File.join(config.project_dir, '.ocak', 'issues', format('%04d.md', issue.to_i))

          unless File.exist?(path)
            warn "Issue ##{issue} not found at #{path}"
            exit 1
          end

          editor = ENV.fetch('EDITOR', 'vi')
          system(editor, path)
        rescue Config::ConfigNotFound => e
          warn "Error: #{e.message}"
          exit 1
        end
      end
    end
  end
end
