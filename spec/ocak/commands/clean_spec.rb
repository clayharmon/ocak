# frozen_string_literal: true

require 'spec_helper'
require 'dry/cli'
require 'ocak/commands/clean'

RSpec.describe Ocak::Commands::Clean do
  subject(:command) { described_class.new }

  let(:config) { instance_double(Ocak::Config, project_dir: '/project', worktree_dir: '.claude/worktrees') }
  let(:manager) { instance_double(Ocak::WorktreeManager) }

  before do
    allow(Ocak::Config).to receive(:load).and_return(config)
    allow(Ocak::WorktreeManager).to receive(:new).and_return(manager)
  end

  it 'reports no stale worktrees when none found' do
    allow(manager).to receive(:clean_stale).and_return([])

    expect { command.call }.to output(/No stale worktrees found/).to_stdout
  end

  it 'reports removed worktrees' do
    allow(manager).to receive(:clean_stale).and_return(['/project/.claude/worktrees/issue-1'])

    expect { command.call }.to output(/Removed:.*issue-1/m).to_stdout
  end

  it 'exits with error on ConfigNotFound' do
    allow(Ocak::Config).to receive(:load).and_raise(Ocak::Config::ConfigNotFound, 'not found')

    expect { command.call }.to raise_error(SystemExit)
  end
end
