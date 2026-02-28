# frozen_string_literal: true

require 'open3'
require 'fileutils'
require 'securerandom'
require 'shellwords'

module Ocak
  class WorktreeManager
    def initialize(config:)
      @config = config
      @worktree_base = File.join(config.project_dir, config.worktree_dir)
      @mutex = Mutex.new
    end

    def create(issue_number, setup_command: nil)
      @mutex.synchronize do
        FileUtils.mkdir_p(@worktree_base)

        branch = "auto/issue-#{issue_number}-#{SecureRandom.hex(4)}"
        path = File.join(@worktree_base, "issue-#{issue_number}")

        _, stderr, status = git('worktree', 'add', '-b', branch, path, 'main')
        raise WorktreeError, "Failed to create worktree: #{stderr}" unless status.success?

        if setup_command
          _, stderr, status = Open3.capture3(*Shellwords.shellsplit(setup_command), chdir: path)
          raise WorktreeError, "Setup command failed: #{stderr}" unless status.success?
        end

        Worktree.new(path: path, branch: branch, issue_number: issue_number)
      end
    end

    def remove(worktree)
      git('worktree', 'remove', '--force', worktree.path)
      git('worktree', 'prune')
    end

    def list
      stdout, _, status = git('worktree', 'list', '--porcelain')
      return [] unless status.success?

      parse_worktree_list(stdout)
    end

    def prune
      git('worktree', 'prune')
    end

    def clean_stale
      removed = []
      list.each do |wt|
        next unless wt[:path]&.include?(@worktree_base)

        begin
          git('worktree', 'remove', '--force', wt[:path])
          removed << wt[:path]
        rescue StandardError
          next # skip failed removal so one bad worktree doesn't abort cleanup of others
        end
      end
      prune
      removed
    end

    Worktree = Struct.new(:path, :branch, :issue_number)

    class WorktreeError < StandardError; end

    private

    def git(*)
      Open3.capture3('git', *, chdir: @config.project_dir)
    end

    def parse_worktree_list(output)
      worktrees = []
      current = {}

      output.each_line do |line|
        line = line.strip
        if line.empty?
          worktrees << current unless current.empty?
          current = {}
        elsif line.start_with?('worktree ')
          current[:path] = line.sub('worktree ', '')
        elsif line.start_with?('branch ')
          current[:branch] = line.sub('branch ', '').sub('refs/heads/', '')
        end
      end
      worktrees << current unless current.empty?
      worktrees
    end
  end
end
