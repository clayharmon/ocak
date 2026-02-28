# frozen_string_literal: true

require 'open3'

module Ocak
  # Runs a subprocess with streaming line output and timeout support.
  module ProcessRunner
    FailedStatus = Struct.new(:success?) do
      def self.instance = new(false)
    end

    module_function

    def run(cmd, chdir:, timeout: nil, on_line: nil, registry: nil)
      stdout = +''
      stderr = +''
      line_buf = +''

      Open3.popen3(*cmd, chdir: chdir) do |stdin, out, err, wait_thr|
        stdin.close
        registry&.register(wait_thr.pid)
        ctx = {
          stdout: +'', stderr: +'', line_buf: +'',
          deadline: timeout ? Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout : nil,
          timeout: timeout, wait_thr: wait_thr, on_line: on_line
        }

        stdout, stderr, line_buf = read_streams(out, err, ctx)
        on_line&.call(line_buf.chomp) unless line_buf.empty?
        [stdout, stderr, wait_thr.value]
      ensure
        registry&.unregister(wait_thr.pid)
      end
    rescue Errno::ENOENT => e
      ['', e.message, FailedStatus.instance]
    end

    def read_streams(out, err, ctx)
      readers = [out, err]

      until readers.empty?
        remaining = ctx[:deadline] ? ctx[:deadline] - Process.clock_gettime(Process::CLOCK_MONOTONIC) : 5

        if ctx[:deadline] && remaining <= 0
          kill_process(ctx[:wait_thr].pid)
          return ['', "Timed out after #{ctx[:timeout]}s", +'']
        end

        read_available(readers, remaining, ctx)
      end

      [ctx[:stdout], ctx[:stderr], ctx[:line_buf]]
    end

    def kill_process(pid)
      Process.kill('TERM', pid)
      sleep 2
      Process.kill('KILL', pid)
    rescue Errno::ESRCH, Errno::EPERM => e
      warn("Process already exited during kill: #{e.message}")
      nil
    end

    def read_available(readers, remaining, ctx)
      ready = IO.select(readers, nil, nil, [remaining, 1].min)
      return unless ready

      ready[0].each do |io|
        chunk = io.read_nonblock(8192)
        if io == readers[0]
          ctx[:stdout] << chunk
          process_lines(ctx[:line_buf], chunk, ctx[:on_line])
        else
          ctx[:stderr] << chunk
        end
      rescue EOFError
        readers.delete(io)
      end
    end

    def process_lines(line_buf, chunk, on_line)
      return unless on_line

      line_buf << chunk
      while (idx = line_buf.index("\n"))
        on_line.call(line_buf.slice!(0, idx + 1).chomp)
      end
    end
  end
end
