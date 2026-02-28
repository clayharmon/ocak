# frozen_string_literal: true

module Ocak
  class ProcessRegistry
    KILL_WAIT = 2

    def initialize
      @pids = Set.new
      @mutex = Mutex.new
    end

    def register(pid)
      @mutex.synchronize { @pids.add(pid) }
    end

    def unregister(pid)
      @mutex.synchronize { @pids.delete(pid) }
    end

    def pids
      @mutex.synchronize { @pids.dup }
    end

    def kill_all(signal: :TERM, wait: KILL_WAIT)
      snapshot = pids
      return if snapshot.empty?

      snapshot.each do |pid|
        Process.kill(signal, pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      sleep wait

      # SIGKILL any survivors; ESRCH means already exited, which is fine
      snapshot.each do |pid|
        Process.kill(:KILL, pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end
  end
end
