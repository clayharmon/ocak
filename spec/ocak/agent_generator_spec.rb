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

  context 'when use_ai: true' do
    subject(:ai_generator) { described_class.new(stack: stack, project_dir: dir, use_ai: true) }

    let(:success_status) { instance_double(Process::Status, success?: true) }
    let(:failure_status) { instance_double(Process::Status, success?: false) }

    describe '#claude_available?' do
      it 'returns true when claude CLI is found' do
        allow(Open3).to receive(:capture3).with('which',
                                                'claude').and_return(['/usr/local/bin/claude', '', success_status])

        expect(ai_generator.send(:claude_available?)).to be true
      end

      it 'returns false when claude CLI is not found' do
        allow(Open3).to receive(:capture3).with('which', 'claude').and_return(['', '', failure_status])

        expect(ai_generator.send(:claude_available?)).to be false
      end

      it 'returns false and logs warning when command raises ENOENT' do
        logger = instance_double(Logger, info: nil, warn: nil)
        gen = described_class.new(stack: stack, project_dir: dir, use_ai: true, logger: logger)
        allow(Open3).to receive(:capture3).with('which', 'claude').and_raise(Errno::ENOENT, 'No such file or directory')

        expect(gen.send(:claude_available?)).to be false
        expect(logger).to have_received(:warn).with(/Claude CLI not found/)
      end
    end

    describe '#gather_project_context' do
      it 'includes CLAUDE.md content when present' do
        File.write(File.join(dir, 'CLAUDE.md'), '# Project Instructions')

        result = ai_generator.send(:gather_project_context)
        expect(result).to include('## CLAUDE.md')
        expect(result).to include('# Project Instructions')
      end

      it 'includes README.md content when present' do
        File.write(File.join(dir, 'README.md'), '# My Project')

        result = ai_generator.send(:gather_project_context)
        expect(result).to include('## README.md')
        expect(result).to include('# My Project')
      end

      it 'includes both files when both are present' do
        File.write(File.join(dir, 'CLAUDE.md'), '# Instructions')
        File.write(File.join(dir, 'README.md'), '# Readme')

        result = ai_generator.send(:gather_project_context)
        expect(result).to include('## CLAUDE.md')
        expect(result).to include('## README.md')
      end

      it 'returns empty string when neither file exists' do
        result = ai_generator.send(:gather_project_context)
        expect(result).to eq('')
      end

      it 'truncates README.md to 2001 characters' do
        long_readme = 'x' * 5000
        File.write(File.join(dir, 'README.md'), long_readme)

        result = ai_generator.send(:gather_project_context)
        readme_content = result.sub('## README.md', '').strip
        expect(readme_content.length).to eq(2001)
      end
    end

    describe '#run_claude_prompt' do
      it 'returns stdout on success' do
        allow(Open3).to receive(:capture3).with(
          'claude', '-p',
          '--output-format', 'text',
          '--model', 'us.anthropic.claude-haiku-4-5-20251001',
          '--allowedTools', 'Read,Glob,Grep',
          '--', 'test prompt',
          chdir: dir
        ).and_return(['enhanced content', '', success_status])

        expect(ai_generator.send(:run_claude_prompt, 'test prompt')).to eq('enhanced content')
      end

      it 'returns nil on failure' do
        allow(Open3).to receive(:capture3).with(
          'claude', '-p',
          '--output-format', 'text',
          '--model', 'us.anthropic.claude-haiku-4-5-20251001',
          '--allowedTools', 'Read,Glob,Grep',
          '--', 'test prompt',
          chdir: dir
        ).and_return(['', 'error', failure_status])

        expect(ai_generator.send(:run_claude_prompt, 'test prompt')).to be_nil
      end

      it 'returns nil and logs warning when command raises ENOENT' do
        logger = instance_double(Logger, info: nil, warn: nil)
        gen = described_class.new(stack: stack, project_dir: dir, use_ai: true, logger: logger)
        allow(Open3).to receive(:capture3).with(
          'claude', '-p',
          '--output-format', 'text',
          '--model', 'us.anthropic.claude-haiku-4-5-20251001',
          '--allowedTools', 'Read,Glob,Grep',
          '--', 'test prompt',
          chdir: dir
        ).and_raise(Errno::ENOENT, 'No such file or directory')

        expect(gen.send(:run_claude_prompt, 'test prompt')).to be_nil
        expect(logger).to have_received(:warn).with(/Failed to run Claude prompt/)
      end
    end

    describe '#enhance_with_ai' do
      let(:output_dir) { File.join(dir, '.claude', 'agents') }
      let(:enhanced_content) { "---\nname: implementer\n---\n# Enhanced Agent" }

      before do
        # Generate base agent files first
        allow(Open3).to receive(:capture3).with('which',
                                                'claude').and_return(['/usr/local/bin/claude', '', success_status])
        generator.generate_agents(output_dir)
      end

      it 'overwrites agent files with enhanced content when claude succeeds' do
        allow(Open3).to receive(:capture3).with('which',
                                                'claude').and_return(['/usr/local/bin/claude', '', success_status])
        allow(Open3).to receive(:capture3).with(
          'claude', '-p',
          '--output-format', 'text',
          '--model', 'us.anthropic.claude-haiku-4-5-20251001',
          '--allowedTools', 'Read,Glob,Grep',
          '--', anything,
          chdir: dir
        ).and_return([enhanced_content, '', success_status])

        File.write(File.join(dir, 'CLAUDE.md'), '# Context')
        ai_generator.generate_agents(output_dir)

        content = File.read(File.join(output_dir, 'implementer.md'))
        expect(content).to eq(enhanced_content)
      end

      it 'keeps original content when claude is unavailable' do
        allow(Open3).to receive(:capture3).with('which', 'claude').and_return(['', '', failure_status])

        File.write(File.join(dir, 'CLAUDE.md'), '# Context')
        original_content = File.read(File.join(output_dir, 'implementer.md'))
        ai_generator.generate_agents(output_dir)

        content = File.read(File.join(output_dir, 'implementer.md'))
        expect(content).to eq(original_content)
      end

      it 'keeps original content when context is empty' do
        allow(Open3).to receive(:capture3).with('which',
                                                'claude').and_return(['/usr/local/bin/claude', '', success_status])

        original_content = File.read(File.join(output_dir, 'implementer.md'))
        ai_generator.generate_agents(output_dir)

        content = File.read(File.join(output_dir, 'implementer.md'))
        expect(content).to eq(original_content)
      end

      it 'keeps original content when claude returns empty response' do
        allow(Open3).to receive(:capture3).with('which',
                                                'claude').and_return(['/usr/local/bin/claude', '', success_status])
        allow(Open3).to receive(:capture3).with(
          'claude', '-p',
          '--output-format', 'text',
          '--model', 'us.anthropic.claude-haiku-4-5-20251001',
          '--allowedTools', 'Read,Glob,Grep',
          '--', anything,
          chdir: dir
        ).and_return(['', '', success_status])

        File.write(File.join(dir, 'CLAUDE.md'), '# Context')
        original_content = File.read(File.join(output_dir, 'implementer.md'))
        ai_generator.generate_agents(output_dir)

        content = File.read(File.join(output_dir, 'implementer.md'))
        expect(content).to eq(original_content)
      end

      it 'keeps original content when claude response lacks frontmatter' do
        allow(Open3).to receive(:capture3).with('which',
                                                'claude').and_return(['/usr/local/bin/claude', '', success_status])
        allow(Open3).to receive(:capture3).with(
          'claude', '-p',
          '--output-format', 'text',
          '--model', 'us.anthropic.claude-haiku-4-5-20251001',
          '--allowedTools', 'Read,Glob,Grep',
          '--', anything,
          chdir: dir
        ).and_return(['no frontmatter here', '', success_status])

        File.write(File.join(dir, 'CLAUDE.md'), '# Context')
        original_content = File.read(File.join(output_dir, 'implementer.md'))
        ai_generator.generate_agents(output_dir)

        content = File.read(File.join(output_dir, 'implementer.md'))
        expect(content).to eq(original_content)
      end
    end
  end
end
