# frozen_string_literal: true

require 'spec_helper'
require 'ocak/pipeline_state'
require 'tmpdir'

RSpec.describe Ocak::PipelineState do
  let(:dir) { Dir.mktmpdir }

  subject(:state) { described_class.new(log_dir: dir) }

  after { FileUtils.remove_entry(dir) }

  describe '#save and #load' do
    it 'saves and loads state for an issue' do
      state.save(42, completed_steps: [0, 1], worktree_path: '/tmp/wt', branch: 'auto/issue-42')

      loaded = state.load(42)
      expect(loaded[:issue_number]).to eq(42)
      expect(loaded[:completed_steps]).to eq([0, 1])
      expect(loaded[:worktree_path]).to eq('/tmp/wt')
      expect(loaded[:branch]).to eq('auto/issue-42')
      expect(loaded[:updated_at]).not_to be_nil
    end

    it 'returns nil for nonexistent issue' do
      expect(state.load(999)).to be_nil
    end

    it 'returns nil on corrupt state file' do
      File.write(File.join(dir, 'issue-42-state.json'), 'not json')
      expect(state.load(42)).to be_nil
    end
  end

  describe '#save error handling' do
    it 'does not raise when File.write fails with Errno::ENOSPC' do
      allow(File).to receive(:write).and_raise(Errno::ENOSPC)

      expect { state.save(42, completed_steps: [0]) }.not_to raise_error
    end

    it 'returns nil on failure' do
      allow(File).to receive(:write).and_raise(Errno::EACCES, 'Permission denied')

      expect(state.save(42, completed_steps: [0])).to be_nil
    end

    it 'warns with issue number and error message' do
      allow(File).to receive(:write).and_raise(Errno::ENOSPC)

      expect { state.save(42, completed_steps: [0]) }.to output(
        /Pipeline state save failed for issue #42/
      ).to_stderr
    end

    it 'uses logger when provided' do
      logger = instance_double(Logger)
      allow(logger).to receive(:warn)
      logged_state = described_class.new(log_dir: dir, logger: logger)
      allow(File).to receive(:write).and_raise(Errno::ENOSPC)

      logged_state.save(42, completed_steps: [0])

      expect(logger).to have_received(:warn).with(/Pipeline state save failed for issue #42/)
    end
  end

  describe '#delete' do
    it 'removes the state file' do
      state.save(42, completed_steps: [0])
      expect(state.load(42)).not_to be_nil

      state.delete(42)
      expect(state.load(42)).to be_nil
    end

    it 'does not raise when file does not exist' do
      expect { state.delete(999) }.not_to raise_error
    end
  end

  describe '#list' do
    it 'returns all saved states' do
      state.save(1, completed_steps: [0])
      state.save(2, completed_steps: [0, 1])

      all = state.list
      expect(all.size).to eq(2)
      expect(all.map { |s| s[:issue_number] }).to contain_exactly(1, 2)
    end

    it 'returns empty array when no states exist' do
      expect(state.list).to eq([])
    end

    it 'warns and skips corrupt state files' do
      state.save(1, completed_steps: [0])
      File.write(File.join(dir, 'issue-2-state.json'), 'not valid json{{{')
      state.save(3, completed_steps: [0, 1])

      all = nil
      expect { all = state.list }.to output(/Failed to parse pipeline state file/).to_stderr

      expect(all.size).to eq(2)
      expect(all.map { |s| s[:issue_number] }).to contain_exactly(1, 3)
    end
  end
end
