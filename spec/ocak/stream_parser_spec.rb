# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Ocak::StreamParser do
  let(:logger) { instance_double(Ocak::PipelineLogger, info: nil, warn: nil, error: nil, debug: nil) }

  subject(:parser) { described_class.new('reviewer', logger) }

  describe '#parse_line' do
    it 'returns empty array for empty lines' do
      expect(parser.parse_line('')).to eq([])
      expect(parser.parse_line('   ')).to eq([])
    end

    it 'returns empty array for invalid JSON' do
      expect(parser.parse_line('not json')).to eq([])
    end

    it 'returns empty array for unknown type' do
      expect(parser.parse_line('{"type":"unknown"}')).to eq([])
    end

    context 'with system init event' do
      it 'parses model and session_id' do
        line = JSON.generate(type: 'system', subtype: 'init', model: 'claude-4', session_id: 'abc')
        events = parser.parse_line(line)

        expect(events.size).to eq(1)
        expect(events.first).to include(category: :init, model: 'claude-4', session_id: 'abc')
      end

      it 'defaults model to unknown' do
        line = JSON.generate(type: 'system', subtype: 'init')
        events = parser.parse_line(line)

        expect(events.first[:model]).to eq('unknown')
      end

      it 'ignores non-init system events' do
        line = JSON.generate(type: 'system', subtype: 'other')
        expect(parser.parse_line(line)).to eq([])
      end
    end

    context 'with assistant text event' do
      it 'parses text block' do
        line = JSON.generate(type: 'assistant', message: {
                               content: [{ 'type' => 'text', 'text' => 'hello world' }]
                             })
        events = parser.parse_line(line)

        expect(events.size).to eq(1)
        expect(events.first).to include(category: :text, has_findings: false)
      end

      it 'detects red circle as blocking finding' do
        line = JSON.generate(type: 'assistant', message: {
                               content: [{ 'type' => 'text', 'text' => "Issue \u{1F534} found" }]
                             })
        events = parser.parse_line(line)

        expect(events.first).to include(has_findings: true, has_red: true)
      end

      it 'detects yellow circle as warning' do
        line = JSON.generate(type: 'assistant', message: {
                               content: [{ 'type' => 'text', 'text' => "Warning \u{1F7E1}" }]
                             })
        events = parser.parse_line(line)

        expect(events.first).to include(has_findings: true, has_yellow: true, has_red: false)
      end

      it 'detects green circle as pass' do
        line = JSON.generate(type: 'assistant', message: {
                               content: [{ 'type' => 'text', 'text' => "All good \u{1F7E2}" }]
                             })
        events = parser.parse_line(line)

        expect(events.first).to include(has_findings: true, has_green: true)
      end

      it 'truncates text to 200 chars in event hash' do
        long_text = 'x' * 300
        line = JSON.generate(type: 'assistant', message: {
                               content: [{ 'type' => 'text', 'text' => long_text }]
                             })
        events = parser.parse_line(line)

        expect(events.first[:text].length).to eq(201) # 0..200
      end

      it 'accumulates full text in full_output without truncation' do
        long_text = 'x' * 300
        line = JSON.generate(type: 'assistant', message: {
                               content: [{ 'type' => 'text', 'text' => long_text }]
                             })
        parser.parse_line(line)

        expect(parser.full_output).to eq(long_text)
      end

      it 'returns empty for non-array content' do
        line = JSON.generate(type: 'assistant', message: { content: 'string' })
        expect(parser.parse_line(line)).to eq([])
      end
    end

    context 'with tool_use events' do
      it 'tracks Edit tool and records file' do
        line = JSON.generate(type: 'assistant', message: {
                               content: [{ 'type' => 'tool_use', 'id' => 't1', 'name' => 'Edit',
                                           'input' => { 'file_path' => '/foo/bar.rb' } }]
                             })
        events = parser.parse_line(line)

        expect(events.first).to include(category: :tool_call, tool: 'Edit', file_path: '/foo/bar.rb')
        expect(parser.files_edited).to eq(['/foo/bar.rb'])
      end

      it 'tracks Write tool and records file' do
        line = JSON.generate(type: 'assistant', message: {
                               content: [{ 'type' => 'tool_use', 'id' => 't2', 'name' => 'Write',
                                           'input' => { 'file_path' => '/new.rb' } }]
                             })
        parser.parse_line(line)

        expect(parser.files_edited).to eq(['/new.rb'])
      end

      it 'tracks Bash tool with truncation' do
        long_cmd = 'a' * 150
        line = JSON.generate(type: 'assistant', message: {
                               content: [{ 'type' => 'tool_use', 'id' => 't3', 'name' => 'Bash',
                                           'input' => { 'command' => long_cmd } }]
                             })
        events = parser.parse_line(line)

        expect(events.first[:detail]).to end_with('...')
        expect(events.first[:command]).to eq(long_cmd)
      end

      it 'tracks Read tool' do
        line = JSON.generate(type: 'assistant', message: {
                               content: [{ 'type' => 'tool_use', 'id' => 't4', 'name' => 'Read',
                                           'input' => { 'file_path' => '/read.rb' } }]
                             })
        events = parser.parse_line(line)

        expect(events.first).to include(category: :tool_call, tool: 'Read', detail: '/read.rb')
      end

      it 'tracks Glob tool' do
        line = JSON.generate(type: 'assistant', message: {
                               content: [{ 'type' => 'tool_use', 'id' => 't5', 'name' => 'Glob',
                                           'input' => { 'pattern' => '**/*.rb' } }]
                             })
        events = parser.parse_line(line)

        expect(events.first).to include(category: :tool_call, tool: 'Glob', detail: '**/*.rb')
      end

      it 'handles unknown tool' do
        line = JSON.generate(type: 'assistant', message: {
                               content: [{ 'type' => 'tool_use', 'id' => 't6', 'name' => 'WebSearch',
                                           'input' => {} }]
                             })
        events = parser.parse_line(line)

        expect(events.first).to include(category: :tool_call, tool: 'WebSearch', detail: '')
      end
    end

    context 'with tool_result (test detection)' do
      before do
        # First register a Bash tool_use so the result can be correlated
        tool_use_line = JSON.generate(type: 'assistant', message: {
                                        content: [{ 'type' => 'tool_use', 'id' => 'tool-1', 'name' => 'Bash',
                                                    'input' => { 'command' => 'bundle exec rspec' } }]
                                      })
        parser.parse_line(tool_use_line)
      end

      it 'detects passing rspec test' do
        line = JSON.generate(type: 'user', message: {
                               content: [{ 'type' => 'tool_result', 'tool_use_id' => 'tool-1',
                                           'content' => '10 examples, 0 failures, 0 errors' }]
                             })
        events = parser.parse_line(line)

        expect(events.first).to include(category: :tool_result, is_test_result: true, passed: true)
      end

      it 'detects failing test' do
        line = JSON.generate(type: 'user', message: {
                               content: [{ 'type' => 'tool_result', 'tool_use_id' => 'tool-1',
                                           'content' => '3 examples, 2 failures' }]
                             })
        events = parser.parse_line(line)

        expect(events.first).to include(is_test_result: true, passed: false)
      end

      it 'ignores non-test tool results' do
        # Register a non-test Bash tool
        tool_use_line = JSON.generate(type: 'assistant', message: {
                                        content: [{ 'type' => 'tool_use', 'id' => 'tool-2', 'name' => 'Bash',
                                                    'input' => { 'command' => 'ls -la' } }]
                                      })
        parser.parse_line(tool_use_line)

        line = JSON.generate(type: 'user', message: {
                               content: [{ 'type' => 'tool_result', 'tool_use_id' => 'tool-2',
                                           'content' => 'some output' }]
                             })
        events = parser.parse_line(line)

        expect(events).to eq([]) # filter_map drops nil returns
      end
    end

    context 'with result event' do
      it 'parses success result' do
        line = JSON.generate(
          type: 'result', subtype: 'success',
          result: 'Done!', total_cost_usd: 0.05,
          duration_ms: 12_000, num_turns: 5
        )
        events = parser.parse_line(line)

        expect(events.first).to include(category: :result, subtype: 'success', cost_usd: 0.05)
        expect(parser.success?).to be true
        expect(parser.result_text).to eq('Done!')
        expect(parser.cost_usd).to eq(0.05)
        expect(parser.duration_ms).to eq(12_000)
        expect(parser.num_turns).to eq(5)
      end

      it 'parses failed result' do
        line = JSON.generate(type: 'result', subtype: 'error', result: 'Failed')
        parser.parse_line(line)

        expect(parser.success?).to be false
      end
    end
  end

  describe '#success?' do
    it 'defaults to false' do
      expect(parser.success?).to be false
    end
  end

  describe '#full_output' do
    it 'returns empty string when no text blocks parsed' do
      expect(parser.full_output).to eq('')
    end

    it 'accumulates multiple text blocks joined with newlines' do
      %w[first second third].each do |text|
        line = JSON.generate(type: 'assistant', message: {
                               content: [{ 'type' => 'text', 'text' => text }]
                             })
        parser.parse_line(line)
      end

      expect(parser.full_output).to eq("first\nsecond\nthird")
    end

    it 'preserves full text without truncation' do
      long_text = 'a' * 500
      line = JSON.generate(type: 'assistant', message: {
                             content: [{ 'type' => 'text', 'text' => long_text }]
                           })
      parser.parse_line(line)

      expect(parser.full_output.length).to eq(500)
    end

    it 'is independent from result_text' do
      text_line = JSON.generate(type: 'assistant', message: {
                                  content: [{ 'type' => 'text', 'text' => 'intermediate text' }]
                                })
      result_line = JSON.generate(type: 'result', subtype: 'success', result: 'final result',
                                  total_cost_usd: 0.01, duration_ms: 1000, num_turns: 1)
      parser.parse_line(text_line)
      parser.parse_line(result_line)

      expect(parser.full_output).to eq('intermediate text')
      expect(parser.result_text).to eq('final result')
    end
  end

  describe 'debug logging for read-only tools' do
    it 'logs Read tool calls via logger.debug' do
      line = JSON.generate(type: 'assistant', message: {
                             content: [{ 'type' => 'tool_use', 'id' => 'r1', 'name' => 'Read',
                                         'input' => { 'file_path' => '/foo/bar.rb' } }]
                           })
      parser.parse_line(line)

      expect(logger).to have_received(:debug).with('[READ] /foo/bar.rb', agent: 'reviewer')
    end

    it 'logs Glob tool calls via logger.debug' do
      line = JSON.generate(type: 'assistant', message: {
                             content: [{ 'type' => 'tool_use', 'id' => 'g1', 'name' => 'Glob',
                                         'input' => { 'pattern' => '**/*.rb' } }]
                           })
      parser.parse_line(line)

      expect(logger).to have_received(:debug).with('[GLOB] **/*.rb', agent: 'reviewer')
    end

    it 'logs Grep tool calls via logger.debug' do
      line = JSON.generate(type: 'assistant', message: {
                             content: [{ 'type' => 'tool_use', 'id' => 'gr1', 'name' => 'Grep',
                                         'input' => { 'pattern' => 'def poll_interval' } }]
                           })
      parser.parse_line(line)

      expect(logger).to have_received(:debug).with('[GREP] def poll_interval', agent: 'reviewer')
    end

    it 'does not log unknown tools via debug' do
      line = JSON.generate(type: 'assistant', message: {
                             content: [{ 'type' => 'tool_use', 'id' => 'u1', 'name' => 'WebSearch',
                                         'input' => {} }]
                           })
      parser.parse_line(line)

      expect(logger).not_to have_received(:debug)
    end
  end

  describe '#detect_test_pass (via tool_result)' do
    before do
      tool_use_line = JSON.generate(type: 'assistant', message: {
                                      content: [{ 'type' => 'tool_use', 'id' => 'tool-t', 'name' => 'Bash',
                                                  'input' => { 'command' => 'cargo test' } }]
                                    })
      parser.parse_line(tool_use_line)
    end

    def result_for(output)
      line = JSON.generate(type: 'user', message: {
                             content: [{ 'type' => 'tool_result', 'tool_use_id' => 'tool-t',
                                         'content' => output }]
                           })
      parser.parse_line(line).first
    end

    it 'detects rubocop pass' do
      expect(result_for('no offenses detected')[:passed]).to be true
    end

    it 'detects cargo test pass' do
      expect(result_for('test result: ok. 5 passed')[:passed]).to be true
    end

    it 'detects FAIL output' do
      expect(result_for('FAILED some test')[:passed]).to be false
    end

    it 'returns nil when no recognized pattern matches' do
      expect(result_for('some random output')[:passed]).to be_nil
    end

    it 'logs UNKNOWN when no recognized pattern matches' do
      result_for('some random output')
      expect(logger).to have_received(:info).with('[TEST] UNKNOWN (cargo test)', agent: 'reviewer')
    end
  end
end
