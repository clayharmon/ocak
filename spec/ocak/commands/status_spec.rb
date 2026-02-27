# frozen_string_literal: true

require 'spec_helper'
require 'dry/cli'
require 'tmpdir'
require 'ocak/commands/status'

RSpec.describe Ocak::Commands::Status do
  subject(:command) { described_class.new }

  let(:dir) { Dir.mktmpdir }
  let(:config) do
    instance_double(Ocak::Config,
                    project_dir: dir,
                    worktree_dir: '.claude/worktrees',
                    log_dir: 'logs/pipeline',
                    label_ready: 'auto-ready',
                    label_in_progress: 'in-progress',
                    label_completed: 'completed',
                    label_failed: 'pipeline-failed')
  end

  let(:manager) { instance_double(Ocak::WorktreeManager) }

  before do
    allow(Ocak::Config).to receive(:load).and_return(config)
    allow(Ocak::WorktreeManager).to receive(:new).and_return(manager)
    allow(manager).to receive(:list).and_return([])

    # Mock gh issue list for all labels
    allow(Open3).to receive(:capture3) do |*args, **_kwargs|
      if args.include?('gh')
        ['[]', '', instance_double(Process::Status, success?: true)]
      else
        ['', '', instance_double(Process::Status, success?: true)]
      end
    end
  end

  after { FileUtils.remove_entry(dir) }

  it 'displays pipeline status header' do
    expect { command.call }.to output(/Pipeline Status/).to_stdout
  end

  it 'displays issue counts per label' do
    allow(Open3).to receive(:capture3)
      .with('gh', 'issue', 'list', '--label', 'auto-ready', '--state', 'open',
            '--json', 'number', '--limit', '100', chdir: dir)
      .and_return(['[{"number":1},{"number":2}]', '', instance_double(Process::Status, success?: true)])

    expect { command.call }.to output(/ready: 2/).to_stdout
  end

  it 'displays worktrees' do
    allow(manager).to receive(:list).and_return([
                                                  { path: '/project/.claude/worktrees/issue-1',
                                                    branch: 'auto/issue-1-abc' }
                                                ])

    expect { command.call }.to output(%r{auto/issue-1-abc}).to_stdout
  end

  it 'displays recent logs' do
    log_dir = File.join(dir, 'logs', 'pipeline')
    FileUtils.mkdir_p(log_dir)
    File.write(File.join(log_dir, 'issue-1.log'), 'x' * 100)

    expect { command.call }.to output(/issue-1\.log/).to_stdout
  end

  it 'shows no active worktrees message when empty' do
    expect { command.call }.to output(/No active pipeline worktrees/).to_stdout
  end

  it 'exits with error on ConfigNotFound' do
    allow(Ocak::Config).to receive(:load).and_raise(Ocak::Config::ConfigNotFound, 'not found')

    expect { command.call }.to raise_error(SystemExit)
  end
end
