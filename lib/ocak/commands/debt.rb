# frozen_string_literal: true

module Ocak
  module Commands
    class Debt < Dry::CLI::Command
      desc 'Track technical debt'

      def call(**)
        skill_path = File.join(Dir.pwd, '.claude', 'skills', 'debt', 'SKILL.md')

        unless File.exist?(skill_path)
          warn 'No debt skill found. Run `ocak init` first.'
          exit 1
        end

        puts 'Run this inside Claude Code:'
        puts '  /debt'
      end
    end
  end
end
