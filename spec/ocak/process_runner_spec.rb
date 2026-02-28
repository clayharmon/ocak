# frozen_string_literal: true

require 'spec_helper'
require 'ocak/process_runner'

RSpec.describe Ocak::ProcessRunner do
  describe '.run' do
    let(:chdir) { '/project' }

    it 'returns stdout, stderr, and status on success' do
      stdin = instance_double(IO, close: nil)
      stdout_r, stdout_w = IO.pipe
      stderr_r, stderr_w = IO.pipe
      stdout_w.write("hello\n")
      stdout_w.close
      stderr_w.close
      wait_thr = double('wait_thr', pid: 1234)
      status = instance_double(Process::Status, success?: true)
      allow(wait_thr).to receive(:value).and_return(status)

      allow(Open3).to receive(:popen3).and_yield(stdin, stdout_r, stderr_r, wait_thr)

      stdout, stderr, result_status = described_class.run(%w[echo hello], chdir: chdir)

      expect(stdout).to eq("hello\n")
      expect(stderr).to eq('')
      expect(result_status).to eq(status)
    ensure
      stdout_r.close unless stdout_r.closed?
      stderr_r.close unless stderr_r.closed?
    end

    it 'returns FailedStatus on Errno::ENOENT' do
      allow(Open3).to receive(:popen3).and_raise(Errno::ENOENT, 'not found')

      stdout, stderr, status = described_class.run(['nonexistent'], chdir: chdir)

      expect(stdout).to eq('')
      expect(stderr).to include('not found')
      expect(status.success?).to be false
    end

    it 'calls on_line callback for each line' do
      stdin = instance_double(IO, close: nil)
      stdout_r, stdout_w = IO.pipe
      stderr_r, stderr_w = IO.pipe
      stdout_w.write("line1\nline2\n")
      stdout_w.close
      stderr_w.close
      wait_thr = double('wait_thr', pid: 1234)
      status = instance_double(Process::Status, success?: true)
      allow(wait_thr).to receive(:value).and_return(status)

      allow(Open3).to receive(:popen3).and_yield(stdin, stdout_r, stderr_r, wait_thr)

      lines = []
      described_class.run(['cmd'], chdir: chdir, on_line: ->(line) { lines << line })

      expect(lines).to eq(%w[line1 line2])
    ensure
      stdout_r.close unless stdout_r.closed?
      stderr_r.close unless stderr_r.closed?
    end

    it 'does not emit warnings to stderr on normal subprocess completion' do
      stdin = instance_double(IO, close: nil)
      stdout_r, stdout_w = IO.pipe
      stderr_r, stderr_w = IO.pipe
      stdout_w.write("output\n")
      stdout_w.close
      stderr_w.close
      wait_thr = double('wait_thr', pid: 1234)
      status = instance_double(Process::Status, success?: true)
      allow(wait_thr).to receive(:value).and_return(status)

      allow(Open3).to receive(:popen3).and_yield(stdin, stdout_r, stderr_r, wait_thr)

      expect { described_class.run(%w[echo output], chdir: chdir) }.not_to output.to_stderr
    ensure
      stdout_r.close unless stdout_r.closed?
      stderr_r.close unless stderr_r.closed?
    end

    it 'handles timeout by killing the process' do
      stdin = instance_double(IO, close: nil)
      stdout_r, stdout_w = IO.pipe
      stderr_r, stderr_w = IO.pipe
      stderr_w.close
      wait_thr = double('wait_thr', pid: 99_999)
      status = instance_double(Process::Status, success?: false)
      allow(wait_thr).to receive(:value).and_return(status)

      allow(Open3).to receive(:popen3).and_yield(stdin, stdout_r, stderr_r, wait_thr)
      allow(Process).to receive(:kill)
      allow(described_class).to receive(:sleep)
      # Make the clock return past the deadline immediately
      allow(Process).to receive(:clock_gettime).and_return(100.0, 100.0, 101.0)

      _stdout, stderr, _status = described_class.run(['slow'], chdir: chdir, timeout: 0)

      expect(stderr).to include('Timed out')
    ensure
      stdout_r.close unless stdout_r.closed?
      stdout_w.close unless stdout_w.closed?
      stderr_r.close unless stderr_r.closed?
    end

    it 'completes without raising when Process.kill raises Errno::EPERM' do
      stdin = instance_double(IO, close: nil)
      stdout_r, stdout_w = IO.pipe
      stderr_r, stderr_w = IO.pipe
      stderr_w.close
      wait_thr = double('wait_thr', pid: 99_999)
      status = instance_double(Process::Status, success?: false)
      allow(wait_thr).to receive(:value).and_return(status)

      allow(Open3).to receive(:popen3).and_yield(stdin, stdout_r, stderr_r, wait_thr)
      allow(Process).to receive(:kill).and_raise(Errno::EPERM, 'Operation not permitted')
      allow(described_class).to receive(:sleep)
      allow(Process).to receive(:clock_gettime).and_return(100.0, 100.0, 101.0)

      expect { described_class.run(['slow'], chdir: chdir, timeout: 0) }.not_to raise_error
    ensure
      stdout_r.close unless stdout_r.closed?
      stdout_w.close unless stdout_w.closed?
      stderr_r.close unless stderr_r.closed?
    end

    it 'registers PID with registry after spawn and unregisters after exit' do
      stdin = instance_double(IO, close: nil)
      stdout_r, stdout_w = IO.pipe
      stderr_r, stderr_w = IO.pipe
      stdout_w.write("ok\n")
      stdout_w.close
      stderr_w.close
      wait_thr = double('wait_thr', pid: 5678)
      status = instance_double(Process::Status, success?: true)
      allow(wait_thr).to receive(:value).and_return(status)

      allow(Open3).to receive(:popen3).and_yield(stdin, stdout_r, stderr_r, wait_thr)

      registry = instance_double(Ocak::ProcessRegistry)
      allow(registry).to receive(:register)
      allow(registry).to receive(:unregister)

      described_class.run(%w[echo ok], chdir: chdir, registry: registry)

      expect(registry).to have_received(:register).with(5678)
      expect(registry).to have_received(:unregister).with(5678)
    ensure
      stdout_r.close unless stdout_r.closed?
      stderr_r.close unless stderr_r.closed?
    end

    it 'works when no registry is provided (nil safety)' do
      stdin = instance_double(IO, close: nil)
      stdout_r, stdout_w = IO.pipe
      stderr_r, stderr_w = IO.pipe
      stdout_w.write("ok\n")
      stdout_w.close
      stderr_w.close
      wait_thr = double('wait_thr', pid: 5678)
      status = instance_double(Process::Status, success?: true)
      allow(wait_thr).to receive(:value).and_return(status)

      allow(Open3).to receive(:popen3).and_yield(stdin, stdout_r, stderr_r, wait_thr)

      expect { described_class.run(%w[echo ok], chdir: chdir, registry: nil) }.not_to raise_error
    ensure
      stdout_r.close unless stdout_r.closed?
      stderr_r.close unless stderr_r.closed?
    end
  end

  describe 'FailedStatus' do
    it 'reports not success' do
      expect(described_class::FailedStatus.instance.success?).to be false
    end
  end
end
