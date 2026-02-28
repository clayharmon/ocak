# frozen_string_literal: true

require 'spec_helper'
require 'dry/cli'
require 'fileutils'
require 'tmpdir'
require 'ocak/commands/clean'

RSpec.describe Ocak::Commands::Clean do
  subject(:command) { described_class.new }

  let(:tmpdir) { Dir.mktmpdir }
  let(:log_dir_rel) { 'logs/pipeline' }
  let(:log_dir) { File.join(tmpdir, log_dir_rel) }
  let(:reports_dir) { File.join(tmpdir, '.ocak', 'reports') }
  let(:config) do
    instance_double(
      Ocak::Config,
      project_dir: tmpdir,
      worktree_dir: '.claude/worktrees',
      log_dir: log_dir_rel
    )
  end
  let(:manager) { instance_double(Ocak::WorktreeManager) }

  before do
    allow(Ocak::Config).to receive(:load).and_return(config)
    allow(Ocak::WorktreeManager).to receive(:new).and_return(manager)
    allow(manager).to receive(:clean_stale).and_return([])
  end

  after { FileUtils.remove_entry(tmpdir) }

  describe 'default behavior (no flags)' do
    it 'reports no stale worktrees when none found' do
      expect { command.call }.to output(/No stale worktrees found/).to_stdout
    end

    it 'reports removed worktrees' do
      allow(manager).to receive(:clean_stale).and_return(['/project/.claude/worktrees/issue-1'])

      expect { command.call }.to output(/Removed:.*issue-1/m).to_stdout
    end

    it 'does not clean logs' do
      FileUtils.mkdir_p(log_dir)
      log_file = File.join(log_dir, 'issue-42.log')
      FileUtils.touch(log_file)

      command.call

      expect(File.exist?(log_file)).to be true
    end

    it 'exits with error on ConfigNotFound' do
      allow(Ocak::Config).to receive(:load).and_raise(Ocak::Config::ConfigNotFound, 'not found')

      expect { command.call }.to raise_error(SystemExit)
    end
  end

  describe '--logs flag' do
    before do
      FileUtils.mkdir_p(log_dir)
      FileUtils.mkdir_p(reports_dir)
    end

    it 'removes .log files' do
      log_file = File.join(log_dir, '20260228-103000-issue-42.log')
      FileUtils.touch(log_file)

      expect { command.call(logs: true) }.to output(/Removed:.*issue-42\.log/).to_stdout
      expect(File.exist?(log_file)).to be false
    end

    it 'removes state files' do
      state_file = File.join(log_dir, 'issue-42-state.json')
      FileUtils.touch(state_file)

      expect { command.call(logs: true) }.to output(/Removed:.*issue-42-state\.json/).to_stdout
      expect(File.exist?(state_file)).to be false
    end

    it 'removes sidecar directories' do
      sidecar_dir = File.join(log_dir, 'issue-42')
      FileUtils.mkdir_p(sidecar_dir)

      expect { command.call(logs: true) }.to output(/Removed:.*issue-42/).to_stdout
      expect(Dir.exist?(sidecar_dir)).to be false
    end

    it 'removes report files' do
      report_file = File.join(reports_dir, 'issue-42-20260228-103000.json')
      FileUtils.touch(report_file)

      expect { command.call(logs: true) }.to output(/Removed:.*issue-42-20260228-103000\.json/).to_stdout
      expect(File.exist?(report_file)).to be false
    end

    it 'prints summary count' do
      FileUtils.touch(File.join(log_dir, '20260228-103000-issue-42.log'))
      FileUtils.touch(File.join(log_dir, '20260228-091500-issue-39.log'))

      expect { command.call(logs: true) }.to output(/Cleaned 2 artifact\(s\)\./).to_stdout
    end

    it 'does not clean worktrees' do
      expect(manager).not_to receive(:clean_stale)

      command.call(logs: true)
    end

    it 'handles missing log directory gracefully' do
      FileUtils.remove_entry(log_dir)

      expect { command.call(logs: true) }.not_to raise_error
    end

    it 'handles missing reports directory gracefully' do
      FileUtils.remove_entry(reports_dir)

      expect { command.call(logs: true) }.not_to raise_error
    end

    it 'reports no artifacts when none found' do
      expect { command.call(logs: true) }.to output(/No artifacts to clean/).to_stdout
    end

    it 'prints cleaning message' do
      expect { command.call(logs: true) }.to output(/Cleaning logs\.\.\./).to_stdout
    end
  end

  describe '--all flag' do
    before do
      FileUtils.mkdir_p(log_dir)
      FileUtils.mkdir_p(reports_dir)
    end

    it 'cleans worktrees' do
      expect(manager).to receive(:clean_stale).and_return([])

      command.call(all: true)
    end

    it 'cleans logs' do
      log_file = File.join(log_dir, 'issue-42.log')
      FileUtils.touch(log_file)

      command.call(all: true)

      expect(File.exist?(log_file)).to be false
    end

    it 'prints both cleaning messages' do
      expect { command.call(all: true) }.to output(/Cleaning stale worktrees.*Cleaning logs/m).to_stdout
    end
  end

  describe '--keep flag' do
    before do
      FileUtils.mkdir_p(log_dir)
      FileUtils.mkdir_p(reports_dir)
    end

    it 'removes files older than N days' do
      old_file = File.join(log_dir, 'old-issue-35.log')
      FileUtils.touch(old_file)
      old_time = Time.now - (8 * 86_400)
      File.utime(old_time, old_time, old_file)

      command.call(logs: true, keep: 7)

      expect(File.exist?(old_file)).to be false
    end

    it 'keeps files newer than N days' do
      new_file = File.join(log_dir, 'new-issue-42.log')
      FileUtils.touch(new_file)

      command.call(logs: true, keep: 7)

      expect(File.exist?(new_file)).to be true
    end

    it 'prints age-based cleaning message' do
      expect { command.call(logs: true, keep: 7) }.to output(/Cleaning logs older than 7 days/).to_stdout
    end

    it 'prints summary of removed files' do
      old_file = File.join(log_dir, 'old-issue-35.log')
      FileUtils.touch(old_file)
      old_time = Time.now - (8 * 86_400)
      File.utime(old_time, old_time, old_file)

      expect { command.call(logs: true, keep: 7) }.to output(/Cleaned 1 artifact\(s\)\./).to_stdout
    end
  end
end
