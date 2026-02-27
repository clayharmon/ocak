# frozen_string_literal: true

require 'spec_helper'
require 'dry/cli'
require 'tmpdir'
require 'ocak/commands/init'

RSpec.describe Ocak::Commands::Init do
  subject(:command) { described_class.new }

  let(:dir) { Dir.mktmpdir }
  let(:stack) do
    Ocak::StackDetector::Result.new(
      language: 'ruby',
      framework: 'rails',
      test_command: 'bundle exec rspec',
      lint_command: 'bundle exec rubocop -A',
      format_command: nil,
      security_commands: %w[brakeman],
      setup_command: 'bundle install',
      monorepo: false,
      packages: []
    )
  end

  let(:generator) do
    instance_double(Ocak::AgentGenerator,
                    generate_config: nil,
                    generate_agents: nil,
                    generate_skills: nil,
                    generate_hooks: nil)
  end

  before do
    allow(Dir).to receive(:pwd).and_return(dir)
    allow(Ocak::StackDetector).to receive_message_chain(:new, :detect).and_return(stack)
    allow(Ocak::AgentGenerator).to receive(:new).and_return(generator)
    # Stub templates_dir for gitignore
    additions_path = File.join(dir, 'gitignore_additions.txt')
    File.write(additions_path, "logs/\n.claude/worktrees/\n")
    allow(Ocak).to receive(:templates_dir).and_return(dir)
  end

  after { FileUtils.remove_entry(dir) }

  it 'detects stack and generates all files' do
    expect { command.call }.to output(/Ocak initialized successfully/).to_stdout

    expect(generator).to have_received(:generate_config)
    expect(generator).to have_received(:generate_agents)
    expect(generator).to have_received(:generate_skills)
    expect(generator).to have_received(:generate_hooks)
  end

  it 'skips when ocak.yml exists without --force' do
    File.write(File.join(dir, 'ocak.yml'), 'existing: true')

    expect { command.call }.to output(/already exists/).to_stdout

    expect(generator).not_to have_received(:generate_config)
  end

  it 'overwrites when ocak.yml exists with --force' do
    File.write(File.join(dir, 'ocak.yml'), 'existing: true')

    expect { command.call(force: true) }.to output(/Ocak initialized/).to_stdout

    expect(generator).to have_received(:generate_config)
  end

  it 'skips agents with --skip_agents' do
    expect { command.call(skip_agents: true) }.to output(/Ocak initialized/).to_stdout

    expect(generator).not_to have_received(:generate_agents)
  end

  it 'skips skills with --skip_skills' do
    expect { command.call(skip_skills: true) }.to output(/Ocak initialized/).to_stdout

    expect(generator).not_to have_received(:generate_skills)
  end

  it 'skips agents and skills with --config_only' do
    expect { command.call(config_only: true) }.to output(/Ocak initialized/).to_stdout

    expect(generator).not_to have_received(:generate_agents)
    expect(generator).not_to have_received(:generate_skills)
  end

  it 'creates settings.json with permissions' do
    command.call

    settings_path = File.join(dir, '.claude', 'settings.json')
    expect(File.exist?(settings_path)).to be true

    settings = JSON.parse(File.read(settings_path))
    expect(settings['permissions']['allow']).to include('Bash(bundle exec rspec*)')
  end

  it 'updates .gitignore' do
    command.call

    gitignore = File.read(File.join(dir, '.gitignore'))
    expect(gitignore).to include('logs/')
  end
end
