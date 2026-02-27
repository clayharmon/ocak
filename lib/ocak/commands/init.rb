# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative '../stack_detector'
require_relative '../agent_generator'
require_relative '../config'

module Ocak
  module Commands
    class Init < Dry::CLI::Command
      desc 'Initialize Ocak pipeline in the current project'

      option :force, type: :boolean, default: false, desc: 'Overwrite existing configuration'
      option :no_ai, type: :boolean, default: false, desc: 'Skip AI-powered agent customization'

      def call(**options)
        project_dir = Dir.pwd

        if File.exist?(File.join(project_dir, 'ocak.yml')) && !options[:force]
          puts 'ocak.yml already exists. Use --force to overwrite.'
          return
        end

        puts 'Detecting project stack...'
        stack = StackDetector.new(project_dir).detect
        print_stack(stack)

        generator = AgentGenerator.new(
          stack: stack,
          project_dir: project_dir,
          use_ai: !options[:no_ai],
          logger: init_logger
        )

        # Generate config
        generator.generate_config(File.join(project_dir, 'ocak.yml'))

        # Generate agents
        agents_dir = File.join(project_dir, '.claude', 'agents')
        generator.generate_agents(agents_dir)

        # Generate skills
        skills_dir = File.join(project_dir, '.claude', 'skills')
        generator.generate_skills(skills_dir)

        # Generate hooks
        hooks_dir = File.join(project_dir, '.claude', 'hooks')
        generator.generate_hooks(hooks_dir)

        # Update settings.json
        update_settings(project_dir, stack)

        # Update .gitignore
        update_gitignore(project_dir)

        puts ''
        print_summary(project_dir, stack)
      end

      private

      def print_stack(stack)
        puts "  Language:  #{stack.language}"
        puts "  Framework: #{stack.framework || 'none detected'}"
        puts "  Tests:     #{stack.test_command || 'none detected'}"
        puts "  Lint:      #{stack.lint_command || 'none detected'}"
        puts "  Security:  #{stack.security_commands.empty? ? 'none detected' : stack.security_commands.join(', ')}"
        puts ''
      end

      def update_settings(project_dir, stack)
        settings_path = File.join(project_dir, '.claude', 'settings.json')
        existing = File.exist?(settings_path) ? JSON.parse(File.read(settings_path)) : {}

        merge_permissions(existing, stack)
        merge_hooks(existing)

        FileUtils.mkdir_p(File.dirname(settings_path))
        File.write(settings_path, JSON.pretty_generate(existing))
        puts '  Updated .claude/settings.json'
      end

      def merge_permissions(settings, stack)
        settings['permissions'] ||= {}
        settings['permissions']['allow'] ||= []
        allowed = settings['permissions']['allow']

        build_permissions(stack).each do |perm|
          allowed << perm unless allowed.include?(perm)
        end
      end

      def merge_hooks(settings)
        settings['hooks'] ||= {}
        settings['hooks']['PostToolUse'] ||= []
        settings['hooks']['TaskCompleted'] ||= []

        add_hook_unless_exists(settings['hooks']['PostToolUse'], 'post-edit-lint',
                               'matcher' => 'Edit|Write',
                               'hooks' => [{ 'type' => 'command', 'command' => '.claude/hooks/post-edit-lint.sh' }])

        add_hook_unless_exists(settings['hooks']['TaskCompleted'], 'task-completed-test',
                               'hooks' => [{ 'type' => 'command',
                                             'command' => '.claude/hooks/task-completed-test.sh' }])
      end

      def add_hook_unless_exists(hooks_list, hook_name, hook_entry)
        return if hooks_list.any? { |h| h.dig('hooks', 0, 'command')&.include?(hook_name) }

        hooks_list << hook_entry
      end

      def build_permissions(stack)
        perms = language_permissions(stack)
        # Always allow gh CLI for pipeline operations
        perms.push('Bash(gh issue*)', 'Bash(gh pr*)', 'Bash(gh label*)')
      end

      def language_permissions(stack)
        case stack.language
        when 'ruby'
          ruby_permissions(stack)
        when 'typescript', 'javascript'
          ['Bash(npm test*)', 'Bash(npx biome*)', 'Bash(npx eslint*)', 'Bash(npm audit*)', 'Bash(npm run typecheck*)']
        when 'python'
          ['Bash(pytest*)', 'Bash(python -m pytest*)', 'Bash(ruff*)', 'Bash(flake8*)']
        when 'rust'
          ['Bash(cargo test*)', 'Bash(cargo clippy*)', 'Bash(cargo fmt*)']
        when 'go'
          ['Bash(go test*)', 'Bash(golangci-lint*)']
        else
          []
        end
      end

      def ruby_permissions(stack)
        perms = ['Bash(bundle exec rubocop*)', 'Bash(bundle exec rspec*)', 'Bash(bundle exec rake test*)']
        perms << 'Bash(bundle exec brakeman*)' if stack.security_commands.any? { |c| c.include?('brakeman') }
        perms << 'Bash(bundle exec bundler-audit*)' if stack.security_commands.any? { |c| c.include?('bundler-audit') }
        perms
      end

      def update_gitignore(project_dir)
        gitignore_path = File.join(project_dir, '.gitignore')
        additions_path = File.join(Ocak.templates_dir, 'gitignore_additions.txt')
        additions = File.read(additions_path)

        existing = File.exist?(gitignore_path) ? File.read(gitignore_path) : ''

        new_lines = additions.lines.reject do |line|
          line.strip.empty? || line.start_with?('#') || existing.include?(line.strip)
        end

        return if new_lines.empty?

        File.open(gitignore_path, 'a') do |f|
          f.puts '' unless existing.end_with?("\n\n")
          f.puts '# Ocak / Claude Code'
          new_lines.each { |line| f.puts line }
        end
        puts '  Updated .gitignore'
      end

      def print_summary(_project_dir, _stack)
        puts 'Ocak initialized successfully!'
        puts ''
        puts 'Created:'
        puts '  ocak.yml                          — pipeline configuration'
        puts '  .claude/agents/                    — 8 pipeline agents'
        puts '  .claude/skills/                    — 4 interactive skills'
        puts '  .claude/hooks/                     — lint + test hooks'
        puts '  .claude/settings.json              — permissions & hooks config'
        puts ''
        puts 'Next steps:'
        puts '  1. Review ocak.yml and adjust settings'
        puts '  2. Review .claude/agents/ and customize if needed'
        puts '  3. Create issues with: claude then /design'
        puts "  4. Label issues 'auto-ready'"
        puts '  5. Run the pipeline: ocak run --once'
        puts ''
        puts 'Quick commands:'
        puts '  ocak run --single 42    Run one issue'
        puts '  ocak run --watch        Run with live output'
        puts '  ocak status             Check pipeline state'
        puts '  ocak audit              Run codebase audit'
      end

      def init_logger
        # Simple logger that prints to stdout during init
        @init_logger ||= Object.new.tap do |l|
          def l.info(msg)
            puts "  #{msg}"
          end
        end
      end
    end
  end
end
