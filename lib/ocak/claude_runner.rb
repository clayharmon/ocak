# frozen_string_literal: true

require 'open3'
require 'json'
require_relative 'process_runner'
require_relative 'stream_parser'

module Ocak
  class ClaudeRunner
    AgentResult = Struct.new(:success, :output, :cost_usd, :duration_ms,
                             :num_turns, :files_edited) do
      def success? = success
      def blocking_findings? = output.to_s.include?("\u{1F534}")
      def warnings?          = output.to_s.include?("\u{1F7E1}")
    end

    FailedStatus = Struct.new(:success?) do
      def self.instance = new(false)
    end

    AGENT_TOOLS = {
      'implementer' => 'Read,Write,Edit,Glob,Grep,Bash',
      'reviewer' => 'Read,Grep,Glob,Bash',
      'security-reviewer' => 'Read,Grep,Glob,Bash',
      'auditor' => 'Read,Grep,Glob,Bash',
      'documenter' => 'Read,Write,Edit,Glob,Grep,Bash',
      'merger' => 'Read,Glob,Grep,Bash',
      'pipeline' => 'Read,Write,Edit,Glob,Grep,Bash',
      'planner' => 'Read,Glob,Grep,Bash'
    }.freeze

    TIMEOUT = 600 # 10 minutes per agent invocation

    def initialize(config:, logger:, watch: nil)
      @config = config
      @logger = logger
      @watch = watch
    end

    def run_agent(agent_name, prompt, chdir: nil)
      chdir ||= @config.project_dir
      agent_file = @config.agent_path(agent_name)

      unless File.exist?(agent_file)
        @logger.error("Agent file not found: #{agent_file}", agent: agent_name)
        return AgentResult.new(success: false, output: "Agent file not found: #{agent_file}")
      end

      instructions = File.read(agent_file)
      full_prompt = "#{instructions}\n\n---\n\nTask: #{prompt}"
      allowed_tools = AGENT_TOOLS.fetch(agent_name, 'Read,Glob,Grep,Bash')

      @logger.info("Running agent: #{agent_name}", agent: agent_name)

      parser = StreamParser.new(agent_name, @logger)
      line_handler = build_line_handler(agent_name, parser)

      _, stderr, status = run_claude(full_prompt, allowed_tools, chdir: chdir, on_line: line_handler)

      build_agent_result(parser, status, stderr, agent_name)
    end

    # Run a raw prompt without agent file (for planner, init analysis, etc.)
    def run_prompt(prompt, allowed_tools: 'Read,Glob,Grep,Bash', chdir: nil)
      chdir ||= @config.project_dir

      stdout, _, status = run_claude(prompt, allowed_tools, chdir: chdir)

      # Try to extract result from stream-json, fall back to raw stdout
      result_text = extract_result_from_stream(stdout) || stdout
      success = status.respond_to?(:success?) && status.success?

      AgentResult.new(success: success, output: result_text)
    end

    private

    def build_agent_result(parser, status, stderr, agent_name)
      output = parser.result_text || ''
      exit_ok = status.respond_to?(:success?) && status.success?
      success = parser.success? && exit_ok

      @logger.info("Finished (exit: #{exit_ok}, stream: #{parser.success?})", agent: agent_name)
      @logger.warn("Stderr: #{stderr[0..300]}", agent: agent_name) unless stderr.to_s.empty?

      AgentResult.new(
        success: success,
        output: output,
        cost_usd: parser.cost_usd,
        duration_ms: parser.duration_ms,
        num_turns: parser.num_turns,
        files_edited: parser.files_edited
      )
    end

    def build_line_handler(agent_name, parser)
      lambda do |line|
        events = parser.parse_line(line)
        events.each { |event| @watch&.emit(agent_name, event) }
      end
    end

    def run_claude(prompt, allowed_tools, chdir:, on_line: nil)
      cmd = [
        'claude', '-p',
        '--verbose',
        '--output-format', 'stream-json',
        '--allowedTools', allowed_tools,
        '--', prompt
      ]

      ProcessRunner.run(cmd, chdir: chdir, timeout: TIMEOUT, on_line: on_line)
    end

    def extract_result_from_stream(raw)
      raw.each_line do |line|
        data = JSON.parse(line.strip)
        return data['result'] if data['type'] == 'result'
      rescue JSON::ParserError
        next
      end
      nil
    end
  end
end
