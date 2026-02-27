# frozen_string_literal: true

module Ocak
  module Commands
    class Design < Dry::CLI::Command
      desc 'Launch interactive issue design session'

      argument :description, type: :string, required: false, desc: 'Rough description of what to build'

      def call(description: nil, **)
        skill_path = File.join(Dir.pwd, '.claude', 'skills', 'design', 'SKILL.md')

        unless File.exist?(skill_path)
          warn 'No design skill found. Run `ocak init` first.'
          exit 1
        end

        puts 'Starting interactive design session...'
        puts 'This will open Claude Code with the /design skill.'
        puts ''

        if description
          exec('claude', '--skill', skill_path, '--', description)
        else
          puts 'Run this inside Claude Code:'
          puts '  /design <description of what you want to build>'
          puts ''
          puts 'Or provide a description directly:'
          puts '  ocak design "add user authentication with OAuth"'
        end
      end
    end
  end
end
