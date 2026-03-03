# frozen_string_literal: true

require 'open3'

module Ocak
  module CommandRunner
    CommandResult = Struct.new(:stdout, :stderr, :status) do
      def success?
        status&.success? == true
      end

      def output
        stdout.strip
      end

      def error
        stderr[0...500]
      end
    end

    private

    def run_git(*, chdir: nil)
      run_command('git', *, chdir: chdir)
    end

    def run_gh(*, chdir: nil)
      run_command('gh', *, chdir: chdir)
    end

    def run_command(*, chdir: nil)
      opts = chdir ? { chdir: chdir } : {}
      stdout, stderr, status = Open3.capture3(*, **opts)
      CommandResult.new(stdout, stderr, status)
    rescue Errno::ENOENT => e
      CommandResult.new('', e.message, nil)
    end
  end
end
