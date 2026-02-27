# frozen_string_literal: true

require 'open3'
require 'json'

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

  # Runs a subprocess with streaming line output and timeout support.
  module ProcessRunner
    module_function

    def run(cmd, chdir:, timeout: nil, on_line: nil)
      stdout = +''
      stderr = +''
      line_buf = +''

      Open3.popen3(*cmd, chdir: chdir) do |stdin, out, err, wait_thr|
        stdin.close
        ctx = {
          stdout: +'', stderr: +'', line_buf: +'',
          deadline: timeout ? Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout : nil,
          timeout: timeout, wait_thr: wait_thr, on_line: on_line
        }

        stdout, stderr, line_buf = read_streams(out, err, ctx)
        on_line&.call(line_buf.chomp) unless line_buf.empty?
        [stdout, stderr, wait_thr.value]
      end
    rescue Errno::ENOENT => e
      ['', e.message, ClaudeRunner::FailedStatus.instance]
    end

    def read_streams(out, err, ctx)
      readers = [out, err]

      until readers.empty?
        remaining = ctx[:deadline] ? ctx[:deadline] - Process.clock_gettime(Process::CLOCK_MONOTONIC) : 5

        if ctx[:deadline] && remaining <= 0
          kill_process(ctx[:wait_thr].pid)
          return ['', "Timed out after #{ctx[:timeout]}s", +'']
        end

        read_available(readers, remaining, ctx)
      end

      [ctx[:stdout], ctx[:stderr], ctx[:line_buf]]
    end

    def kill_process(pid)
      Process.kill('TERM', pid)
      sleep 2
      Process.kill('KILL', pid)
    rescue Errno::ESRCH
      nil
    end

    def read_available(readers, remaining, ctx)
      ready = IO.select(readers, nil, nil, [remaining, 1].min)
      return unless ready

      ready[0].each do |io|
        chunk = io.read_nonblock(8192)
        if io == readers[0]
          ctx[:stdout] << chunk
          process_lines(ctx[:line_buf], chunk, ctx[:on_line])
        else
          ctx[:stderr] << chunk
        end
      rescue EOFError
        readers.delete(io)
      end
    end

    def process_lines(line_buf, chunk, on_line)
      return unless on_line

      line_buf << chunk
      while (idx = line_buf.index("\n"))
        on_line.call(line_buf.slice!(0, idx + 1).chomp)
      end
    end
  end

  # Parses NDJSON lines from `claude --output-format stream-json`.
  class StreamParser
    TEST_CMD_PATTERN = %r{
      \b(rails\stest|bin/rails\stest|rspec|npm\stest|
      npx\svitest|cargo\stest|pytest|go\stest|mix\stest|
      rubocop|biome|clippy|eslint)\b
    }x

    attr_reader :result_text, :cost_usd, :duration_ms, :num_turns, :files_edited

    def initialize(agent_name, logger)
      @agent_name = agent_name
      @logger = logger
      @result_text = nil
      @cost_usd = nil
      @duration_ms = nil
      @num_turns = nil
      @success = nil
      @files_edited = []
      @pending_tools = {}
    end

    def success?
      @success == true
    end

    def parse_line(line)
      stripped = line.strip
      return [] if stripped.empty?

      data = JSON.parse(stripped)

      case data['type']
      when 'system'    then parse_system(data)
      when 'assistant' then parse_assistant(data)
      when 'user'      then parse_user(data)
      when 'result'    then parse_result(data)
      else []
      end
    rescue JSON::ParserError
      []
    end

    private

    def parse_system(data)
      return [] unless data['subtype'] == 'init'

      model = data['model'] || 'unknown'
      @logger.info("[INIT] session (model: #{model})", agent: @agent_name)
      [{ category: :init, model: model, session_id: data['session_id'] }]
    end

    def parse_assistant(data)
      content = data.dig('message', 'content')
      return [] unless content.is_a?(Array)

      content.filter_map do |block|
        case block['type']
        when 'text'     then parse_text_block(block)
        when 'tool_use' then parse_tool_use(block)
        end
      end
    end

    def parse_text_block(block)
      text = block['text'].to_s
      has_red    = text.include?("\u{1F534}")
      has_yellow = text.include?("\u{1F7E1}")
      has_green  = text.include?("\u{1F7E2}")
      has_findings = has_red || has_yellow || has_green

      if has_findings
        severity = if has_red
                     'BLOCKING'
                   else
                     (has_yellow ? 'WARNING' : 'PASS')
                   end
        @logger.info("[REVIEW] #{severity}", agent: @agent_name)
      end

      { category: :text, text: text[0..200], has_findings: has_findings,
        has_red: has_red, has_yellow: has_yellow, has_green: has_green }
    end

    def parse_tool_use(block)
      tool_id = block['id']
      tool_name = block['name']
      input = block['input'] || {}
      @pending_tools[tool_id] = { name: tool_name, input: input }

      build_tool_event(tool_name, input)
    end

    def build_tool_event(tool_name, input)
      case tool_name
      when 'Edit', 'Write'
        file_path = input['file_path'].to_s
        @files_edited << file_path unless file_path.empty?
        @logger.info("[EDIT] #{tool_name}: #{file_path}", agent: @agent_name)
        { category: :tool_call, tool: tool_name, detail: file_path, file_path: file_path }
      when 'Bash'
        cmd = input['command'].to_s
        truncated = cmd.length > 100 ? "#{cmd[0..97]}..." : cmd
        @logger.info("[BASH] #{truncated}", agent: @agent_name)
        { category: :tool_call, tool: tool_name, detail: truncated, command: cmd }
      else
        build_read_tool_event(tool_name, input)
      end
    end

    def build_read_tool_event(tool_name, input)
      case tool_name
      when 'Read'
        { category: :tool_call, tool: tool_name, detail: input['file_path'].to_s }
      when 'Glob', 'Grep'
        pattern = (input['pattern'] || input['glob']).to_s
        { category: :tool_call, tool: tool_name, detail: pattern }
      else
        { category: :tool_call, tool: tool_name, detail: '' }
      end
    end

    def parse_user(data)
      content = data.dig('message', 'content')
      return [] unless content.is_a?(Array)

      content.filter_map do |block|
        next unless block['type'] == 'tool_result'

        process_tool_result(block)
      end
    end

    def process_tool_result(block)
      tool_info = @pending_tools[block['tool_use_id']]
      return unless tool_info&.dig(:name) == 'Bash'

      command = tool_info[:input]['command'].to_s
      return unless command.match?(TEST_CMD_PATTERN)

      result_text = extract_tool_text(block['content'])
      passed = detect_test_pass(result_text)
      cmd_label = command[TEST_CMD_PATTERN] || 'test'
      @logger.info("[TEST] #{passed ? 'PASS' : 'FAIL'} (#{cmd_label})", agent: @agent_name)

      { category: :tool_result, is_test_result: true, passed: passed, command: cmd_label }
    end

    def parse_result(data)
      @result_text = data['result'].to_s
      @cost_usd = data['total_cost_usd']
      @duration_ms = data['duration_ms']
      @num_turns = data['num_turns']
      @success = data['subtype'] == 'success'

      cost_str = @cost_usd ? format('$%.4f', @cost_usd) : 'n/a'
      dur_str = @duration_ms ? "#{(@duration_ms / 1000.0).round(1)}s" : 'n/a'
      @logger.info("[DONE] #{@success ? 'success' : 'failed'}, #{cost_str}, #{dur_str}", agent: @agent_name)

      [{ category: :result, subtype: data['subtype'], cost_usd: @cost_usd,
         duration_ms: @duration_ms, num_turns: @num_turns }]
    end

    def extract_tool_text(content)
      case content
      when String then content
      when Array  then content.filter_map { |c| c['text'] if c['type'] == 'text' }.join("\n")
      else ''
      end
    end

    def detect_test_pass(output)
      return true  if output.match?(/0 failures,\s*0 errors/)
      return true  if output.match?(/no offenses detected/i)
      return true  if output.match?(/test result: ok/i) # cargo test
      return false if output.match?(/[1-9]\d* failures?/) || output.match?(/[1-9]\d* errors?/)
      return false if output.match?(/FAIL/i) && !output.match?(/0 failed/i)
      return true  if output.match?(/passed/i) && !output.match?(/failed/i)

      true # no obvious failure signal
    end
  end
end
