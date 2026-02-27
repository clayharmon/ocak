# frozen_string_literal: true

require_relative '../config'
require_relative '../worktree_manager'

module Ocak
  module Commands
    class Clean < Dry::CLI::Command
      desc 'Remove stale worktrees and prune git worktree list'

      def call(**)
        config = Config.load
        manager = WorktreeManager.new(config: config)

        puts 'Cleaning stale worktrees...'
        removed = manager.clean_stale

        if removed.empty?
          puts 'No stale worktrees found.'
        else
          removed.each { |path| puts "  Removed: #{path}" }
          puts "Cleaned #{removed.size} worktree(s)."
        end
      rescue Config::ConfigNotFound => e
        warn "Error: #{e.message}"
        exit 1
      end
    end
  end
end
