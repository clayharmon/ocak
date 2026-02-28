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

        if description
          exec('claude', '--skill', skill_path, '--', description)
        else
          exec('claude', '--skill', skill_path)
        end
      end
    end
  end
end
