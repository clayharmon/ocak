# frozen_string_literal: true

require 'spec_helper'
require 'dry/cli'
require 'tmpdir'
require 'ocak/commands/init'

RSpec.describe Ocak::Commands::Init do
  subject(:command) { described_class.new }

  let(:dir) { Dir.mktmpdir }
  let(:user_config_path) { File.join(dir, 'user_config.yml') }
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
    # Redirect user config to temp dir so tests never write to ~/.config
    allow(Ocak::Config).to receive(:user_config_path).and_return(user_config_path)
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

  it 'recovers from malformed settings.json with a warning' do
    settings_dir = File.join(dir, '.claude')
    FileUtils.mkdir_p(settings_dir)
    File.write(File.join(settings_dir, 'settings.json'), '{invalid json!!!}')

    expect { command.call }.to output(
      %r{Warning: .claude/settings.json is not valid JSON, creating fresh.*Ocak initialized}m
    ).to_stdout

    settings = JSON.parse(File.read(File.join(settings_dir, 'settings.json')))
    expect(settings['permissions']['allow']).to include('Bash(bundle exec rspec*)')
  end

  it 'updates .gitignore' do
    command.call

    gitignore = File.read(File.join(dir, '.gitignore'))
    expect(gitignore).to include('logs/')
  end

  describe 'user config scaffolding' do
    it 'creates user config on first init' do
      command.call
      expect(File.exist?(user_config_path)).to be true
    end

    it 'prints created message for new user config' do
      expect { command.call }.to output(/Created #{Regexp.escape(user_config_path)}/).to_stdout
    end

    it 'does not overwrite user config on second init' do
      File.write(user_config_path, "existing: true\n")

      command.call

      expect(File.read(user_config_path)).to eq("existing: true\n")
    end

    it 'prints skip message when user config already exists' do
      File.write(user_config_path, "existing: true\n")

      expect { command.call }.to output(/#{Regexp.escape(user_config_path)} already exists — skipping/).to_stdout
    end

    it 'user config content contains commented-out repos example' do
      command.call
      content = File.read(user_config_path)
      expect(content).to include('# repos:')
    end

    it 'user config content contains commented-out pipeline example' do
      command.call
      content = File.read(user_config_path)
      expect(content).to include('# pipeline:')
      expect(content).to include('max_parallel:')
    end

    it 'summary mentions user config path' do
      expect { command.call }.to output(/#{Regexp.escape(user_config_path)}/).to_stdout
    end

    it 'does not overwrite user config with --force (only project config)' do
      File.write(user_config_path, "existing: true\n")

      command.call(force: true)

      expect(File.read(user_config_path)).to eq("existing: true\n")
    end
  end
end
