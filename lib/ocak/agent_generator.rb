# frozen_string_literal: true

require 'erb'
require 'fileutils'
require 'open3'

module Ocak
  class AgentGenerator
    AGENT_TEMPLATES = %w[
      implementer reviewer security_reviewer documenter
      merger pipeline planner auditor
    ].freeze

    SKILL_TEMPLATES = %w[design audit scan_file debt].freeze

    def initialize(stack:, project_dir:, use_ai: true, logger: nil)
      @stack = stack
      @project_dir = project_dir
      @use_ai = use_ai
      @logger = logger
    end

    def generate_agents(output_dir)
      FileUtils.mkdir_p(output_dir)

      AGENT_TEMPLATES.each do |agent|
        template_path = File.join(Ocak.templates_dir, 'agents', "#{agent}.md.erb")
        output_name = agent.tr('_', '-')
        output_path = File.join(output_dir, "#{output_name}.md")

        content = render_template(template_path)
        File.write(output_path, content)
        @logger&.info("Generated agent: #{output_name}.md")
      end

      enhance_with_ai(output_dir) if @use_ai
    end

    def generate_skills(output_dir)
      SKILL_TEMPLATES.each do |skill|
        skill_dir = File.join(output_dir, skill.tr('_', '-'))
        FileUtils.mkdir_p(skill_dir)

        template_path = File.join(Ocak.templates_dir, 'skills', skill, 'SKILL.md.erb')
        output_path = File.join(skill_dir, 'SKILL.md')

        content = render_template(template_path)
        File.write(output_path, content)
        @logger&.info("Generated skill: #{skill.tr('_', '-')}/SKILL.md")
      end
    end

    def generate_hooks(output_dir)
      FileUtils.mkdir_p(output_dir)

      %w[post_edit_lint task_completed_test].each do |hook|
        template_path = File.join(Ocak.templates_dir, 'hooks', "#{hook}.sh.erb")
        output_name = hook.tr('_', '-')
        output_path = File.join(output_dir, "#{output_name}.sh")

        content = render_template(template_path)
        File.write(output_path, content)
        File.chmod(0o755, output_path)
        @logger&.info("Generated hook: #{output_name}.sh")
      end
    end

    def generate_config(output_path)
      template_path = File.join(Ocak.templates_dir, 'ocak.yml.erb')
      content = render_template(template_path)
      File.write(output_path, content)
      @logger&.info('Generated ocak.yml')
    end

    private

    def render_template(template_path)
      template = ERB.new(File.read(template_path), trim_mode: '-')
      template.result(template_binding)
    end

    def template_binding
      language = @stack.language
      framework = @stack.framework
      test_command = @stack.test_command
      lint_command = @stack.lint_command
      format_command = @stack.format_command
      security_commands = @stack.security_commands
      setup_command = @stack.setup_command
      monorepo = @stack.respond_to?(:monorepo) ? @stack.monorepo : false
      packages = @stack.respond_to?(:packages) ? (@stack.packages || []) : []
      project_dir = @project_dir
      max_parallel = 5

      binding
    end

    def enhance_with_ai(output_dir)
      return unless claude_available?

      @logger&.info('Enhancing agents with project analysis via Claude...')

      # Read project context
      context = gather_project_context
      return if context.empty?

      AGENT_TEMPLATES.each do |agent|
        output_name = agent.tr('_', '-')
        agent_path = File.join(output_dir, "#{output_name}.md")
        current_content = File.read(agent_path)

        prompt = build_enhancement_prompt(current_content, context)
        result = run_claude_prompt(prompt)

        if result && !result.strip.empty? && result.include?('---')
          File.write(agent_path, result)
          @logger&.info("Enhanced agent with project context: #{output_name}.md")
        end
      end
    end

    def gather_project_context
      parts = []

      claude_md = File.join(@project_dir, 'CLAUDE.md')
      parts << "## CLAUDE.md\n#{File.read(claude_md)}" if File.exist?(claude_md)

      readme = File.join(@project_dir, 'README.md')
      parts << "## README.md\n#{File.read(readme)[0..2000]}" if File.exist?(readme)

      parts.join("\n\n")
    end

    def build_enhancement_prompt(template_content, context)
      <<~PROMPT
        You are customizing a Claude Code agent for a specific project.

        Here is the project context:
        #{context}

        Here is the base agent template:
        #{template_content}

        Customize this agent to reference this project's actual conventions, file paths,
        and patterns. Keep the same structure (YAML frontmatter + markdown). Keep the same
        tool permissions. Make the instructions more specific to this project.

        Output ONLY the complete agent markdown file, nothing else.
      PROMPT
    end

    def claude_available?
      _, _, status = Open3.capture3('which', 'claude')
      status.success?
    rescue Errno::ENOENT => e
      @logger&.warn("Claude CLI not found: #{e.message}")
      false
    end

    def run_claude_prompt(prompt)
      stdout, _, status = Open3.capture3(
        'claude', '-p',
        '--output-format', 'text',
        '--model', 'haiku',
        '--allowedTools', 'Read,Glob,Grep',
        '--', prompt,
        chdir: @project_dir
      )
      status.success? ? stdout : nil
    rescue Errno::ENOENT => e
      @logger&.warn("Failed to run Claude prompt: #{e.message}")
      nil
    end
  end
end
