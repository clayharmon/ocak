# frozen_string_literal: true

require 'spec_helper'
require 'dry/cli'
require 'ocak/commands/run'

RSpec.describe Ocak::Commands::Run do
  subject(:command) { described_class.new }

  let(:config) do
    instance_double(Ocak::Config,
                    project_dir: '/project',
                    label_ready: 'auto-ready',
                    label_in_progress: 'in-progress',
                    label_completed: 'completed',
                    label_failed: 'pipeline-failed',
                    log_dir: 'logs/pipeline',
                    poll_interval: 1,
                    max_parallel: 2,
                    max_issues_per_run: 5,
                    cost_budget: nil,
                    worktree_dir: '.claude/worktrees',
                    test_command: nil,
                    lint_command: nil,
                    lint_check_command: nil,
                    setup_command: nil,
                    language: 'ruby',
                    steps: [{ 'agent' => 'implementer', 'role' => 'implement' }])
  end

  let(:runner) { instance_double(Ocak::PipelineRunner, run: nil) }

  before do
    allow(Ocak::Config).to receive(:load).and_return(config)
    allow(Ocak::PipelineRunner).to receive(:new).and_return(runner)
    allow(command).to receive(:trap)
  end

  it 'loads config and runs the pipeline' do
    command.call

    expect(Ocak::Config).to have_received(:load)
    expect(runner).to have_received(:run)
  end

  it 'overrides max_parallel from CLI options' do
    allow(config).to receive(:override)

    command.call(max_parallel: 5)

    expect(config).to have_received(:override).with(:max_parallel, 5)
  end

  it 'overrides poll_interval from CLI options' do
    allow(config).to receive(:override)

    command.call(poll_interval: 30)

    expect(config).to have_received(:override).with(:poll_interval, 30)
  end

  it 'passes options to PipelineRunner' do
    command.call(watch: true, single: 42, dry_run: true, once: true)

    expect(Ocak::PipelineRunner).to have_received(:new).with(
      config: config,
      options: { watch: true, single: 42, dry_run: true, once: true }
    )
  end

  it 'exits with error on ConfigNotFound' do
    allow(Ocak::Config).to receive(:load).and_raise(Ocak::Config::ConfigNotFound, 'not found')

    expect { command.call }.to raise_error(SystemExit)
  end
end
