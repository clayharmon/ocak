# frozen_string_literal: true

require 'json'

module Ocak
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
