# frozen_string_literal: true

require 'spec_helper'
require 'ocak/process_registry'

RSpec.describe Ocak::ProcessRegistry do
  subject(:registry) { described_class.new }

  describe '#register and #unregister' do
    it 'tracks registered PIDs' do
      registry.register(100)
      registry.register(200)

      expect(registry.pids).to contain_exactly(100, 200)
    end

    it 'removes unregistered PIDs' do
      registry.register(100)
      registry.register(200)
      registry.unregister(100)

      expect(registry.pids).to contain_exactly(200)
    end

    it 'handles unregistering a PID that was never registered' do
      registry.unregister(999)

      expect(registry.pids).to be_empty
    end

    it 'does not duplicate PIDs' do
      registry.register(100)
      registry.register(100)

      expect(registry.pids.size).to eq(1)
    end
  end

  describe '#pids' do
    it 'returns a snapshot (not the internal set)' do
      registry.register(100)
      snapshot = registry.pids
      registry.register(200)

      expect(snapshot).to contain_exactly(100)
      expect(registry.pids).to contain_exactly(100, 200)
    end
  end

  describe '#kill_all' do
    it 'sends SIGTERM then SIGKILL to all registered PIDs' do
      registry.register(100)
      registry.register(200)

      allow(Process).to receive(:kill)
      allow(registry).to receive(:sleep)

      registry.kill_all

      expect(Process).to have_received(:kill).with(:TERM, 100)
      expect(Process).to have_received(:kill).with(:TERM, 200)
      expect(Process).to have_received(:kill).with(:KILL, 100)
      expect(Process).to have_received(:kill).with(:KILL, 200)
      expect(registry).to have_received(:sleep).with(2)
    end

    it 'uses custom signal and wait time' do
      registry.register(100)

      allow(Process).to receive(:kill)
      allow(registry).to receive(:sleep)

      registry.kill_all(signal: :INT, wait: 5)

      expect(Process).to have_received(:kill).with(:INT, 100)
      expect(registry).to have_received(:sleep).with(5)
      expect(Process).to have_received(:kill).with(:KILL, 100)
    end

    it 'handles already-exited PIDs gracefully (Errno::ESRCH)' do
      registry.register(100)

      allow(Process).to receive(:kill).with(:TERM, 100).and_raise(Errno::ESRCH)
      allow(Process).to receive(:kill).with(:KILL, 100).and_raise(Errno::ESRCH)
      allow(registry).to receive(:sleep)

      expect { registry.kill_all }.not_to raise_error
    end

    it 'handles permission errors gracefully (Errno::EPERM)' do
      registry.register(100)

      allow(Process).to receive(:kill).and_raise(Errno::EPERM)
      allow(registry).to receive(:sleep)

      expect { registry.kill_all }.not_to raise_error
    end

    it 'does nothing when registry is empty' do
      allow(Process).to receive(:kill)

      registry.kill_all

      expect(Process).not_to have_received(:kill)
    end
  end

  describe 'thread safety' do
    it 'handles concurrent register/unregister from multiple threads' do
      threads = 10.times.map do |i|
        Thread.new do
          registry.register(i)
          registry.unregister(i)
        end
      end
      threads.each(&:join)

      expect(registry.pids).to be_empty
    end

    it 'handles concurrent registrations' do
      threads = 10.times.map do |i|
        Thread.new { registry.register(i) }
      end
      threads.each(&:join)

      expect(registry.pids.size).to eq(10)
    end
  end
end
