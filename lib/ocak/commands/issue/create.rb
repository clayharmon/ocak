# frozen_string_literal: true

require_relative '../../config'
require_relative '../../local_issue_fetcher'

module Ocak
  module Commands
    module Issue
      class Create < Dry::CLI::Command
        desc 'Create a local issue'

        argument :title, type: :string, required: true, desc: 'Issue title'
        option :body, type: :string, default: '', desc: 'Issue body (opens $EDITOR if omitted)'
        option :label, type: :array, default: [], desc: 'Labels to add (repeatable)'
        option :complexity, type: :string, default: 'full', desc: 'Issue complexity (full or simple)'

        def call(title:, **options)
          config = Config.load
          fetcher = LocalIssueFetcher.new(config: config)

          body = options[:body]
          body = read_from_editor(title) if body.empty?

          number = fetcher.create(
            title: title,
            body: body,
            labels: options[:label],
            complexity: options[:complexity]
          )

          path = File.join('.ocak', 'issues', format('%04d.md', number))
          puts "Created issue ##{number} (#{path})"
        rescue Config::ConfigNotFound => e
          warn "Error: #{e.message}"
          exit 1
        end

        private

        def read_from_editor(title)
          editor = ENV.fetch('EDITOR', 'vi')
          require 'tempfile'
          file = Tempfile.new(['ocak-issue', '.md'])
          file.write("#{title}\n\n")
          file.close

          system(editor, file.path)
          content = File.read(file.path)
          # Strip the title line if it's still there
          lines = content.lines
          lines.shift if lines.first&.strip == title
          lines.join.strip
        ensure
          file&.unlink
        end
      end
    end
  end
end
