# frozen_string_literal: true

require 'spec_helper'
require 'ocak/agent_generator'
require 'tmpdir'

RSpec.describe Ocak::AgentGenerator do
  let(:dir) { Dir.mktmpdir }
  let(:stack) do
    Ocak::StackDetector::Result.new(
      language: 'ruby',
      framework: 'rails',
      test_command: 'bundle exec rspec',
      lint_command: 'bundle exec rubocop -A',
      format_command: nil,
      security_commands: ['bundle exec brakeman -q'],
      setup_command: 'bundle install',
      monorepo: false,
      packages: []
    )
  end

  subject(:generator) { described_class.new(stack: stack, project_dir: dir, use_ai: false) }

  after { FileUtils.remove_entry(dir) }

  describe '#generate_agents' do
    it 'creates all agent files' do
      output_dir = File.join(dir, '.claude', 'agents')
      generator.generate_agents(output_dir)

      expected_files = %w[
        implementer.md reviewer.md security-reviewer.md documenter.md
        merger.md pipeline.md planner.md auditor.md
      ]

      expected_files.each do |file|
        expect(File.exist?(File.join(output_dir, file))).to be(true), "Expected #{file} to exist"
      end
    end

    it 'renders ERB templates with stack variables' do
      output_dir = File.join(dir, '.claude', 'agents')
      generator.generate_agents(output_dir)

      content = File.read(File.join(output_dir, 'implementer.md'))
      expect(content).not_to include('<%')
    end
  end

  describe '#generate_skills' do
    it 'creates all skill directories and files' do
      output_dir = File.join(dir, '.claude', 'skills')
      generator.generate_skills(output_dir)

      %w[design audit scan-file debt].each do |skill|
        skill_file = File.join(output_dir, skill, 'SKILL.md')
        expect(File.exist?(skill_file)).to be(true), "Expected #{skill}/SKILL.md to exist"
      end
    end
  end

  describe '#generate_hooks' do
    it 'creates hook files with executable permissions' do
      output_dir = File.join(dir, '.claude', 'hooks')
      generator.generate_hooks(output_dir)

      %w[post-edit-lint.sh task-completed-test.sh].each do |hook|
        hook_path = File.join(output_dir, hook)
        expect(File.exist?(hook_path)).to be(true), "Expected #{hook} to exist"
        expect(File.executable?(hook_path)).to be(true), "Expected #{hook} to be executable"
      end
    end
  end

  describe '#generate_config' do
    it 'creates ocak.yml' do
      config_path = File.join(dir, 'ocak.yml')
      generator.generate_config(config_path)

      expect(File.exist?(config_path)).to be true
      content = File.read(config_path)
      expect(content).to include('ruby')
    end
  end
end
