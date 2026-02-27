# frozen_string_literal: true

module Ocak
  module Commands
    class Audit < Dry::CLI::Command
      desc 'Run codebase audit'

      argument :scope, type: :string, required: false,
                       desc: 'Audit scope: security, tests, patterns, debt, dependencies, or all'

      def call(scope: nil, **)
        skill_path = File.join(Dir.pwd, '.claude', 'skills', 'audit', 'SKILL.md')

        unless File.exist?(skill_path)
          warn 'No audit skill found. Run `ocak init` first.'
          exit 1
        end

        puts "Starting audit#{" (scope: #{scope})" if scope}..."
        puts 'Run this inside Claude Code:'
        puts "  /audit#{" #{scope}" if scope}"
      end
    end
  end
end
