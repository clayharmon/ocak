# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'stringio'

RSpec.describe Ocak::PipelineLogger do
  describe 'file logging' do
    let(:dir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(dir) }

    it 'creates a log file with timestamp' do
      logger = described_class.new(log_dir: dir, color: false)
      logger.info('test message')

      expect(logger.log_file_path).to match(%r{#{dir}/\d{8}-\d{6}-pipeline\.log})
      expect(File.read(logger.log_file_path)).to include('test message')
    end

    it 'includes issue number in filename when provided' do
      logger = described_class.new(log_dir: dir, issue_number: 42, color: false)
      logger.info('test')

      expect(logger.log_file_path).to include('issue-42.log')
    end

    it 'logs at different levels' do
      logger = described_class.new(log_dir: dir, color: false)
      logger.info('info msg')
      logger.warn('warn msg')
      logger.error('error msg')

      content = File.read(logger.log_file_path)
      expect(content).to include('INFO: info msg')
      expect(content).to include('WARN: warn msg')
      expect(content).to include('ERROR: error msg')
    end
  end

  describe 'terminal output' do
    it 'outputs plain text when color is disabled' do
      logger = described_class.new(color: false)
      expect { logger.info('plain') }.to output(/INFO: plain/).to_stderr_from_any_process
    end
  end

  describe 'log level suppression' do
    it 'suppresses info messages in quiet mode' do
      logger = described_class.new(color: false, log_level: :quiet)
      expect { logger.info('hidden') }.not_to output.to_stderr_from_any_process
    end

    it 'still outputs warn messages in quiet mode' do
      logger = described_class.new(color: false, log_level: :quiet)
      expect { logger.warn('visible') }.to output(/WARN: visible/).to_stderr_from_any_process
    end

    it 'suppresses debug messages in normal mode' do
      logger = described_class.new(color: false, log_level: :normal)
      expect { logger.debug('hidden') }.not_to output.to_stderr_from_any_process
    end

    it 'outputs debug messages in verbose mode' do
      logger = described_class.new(color: false, log_level: :verbose)
      expect { logger.debug('visible') }.to output(/DEBUG: visible/).to_stderr_from_any_process
    end

    it 'writes debug to file logger even in normal mode' do
      dir = Dir.mktmpdir
      logger = described_class.new(log_dir: dir, color: false, log_level: :normal)
      logger.debug('file only')

      content = File.read(logger.log_file_path)
      expect(content).to include('file only')
    ensure
      FileUtils.remove_entry(dir)
    end
  end
end

RSpec.describe Ocak::WatchFormatter do
  let(:io) { StringIO.new }

  subject(:formatter) { described_class.new(io) }

  describe '#emit' do
    it 'ignores nil events' do
      formatter.emit('reviewer', nil)
      expect(io.string).to be_empty
    end

    it 'formats init event' do
      formatter.emit('reviewer', { category: :init, model: 'claude-4' })
      expect(io.string).to include('reviewer')
      expect(io.string).to include('claude-4')
    end

    it 'formats Edit tool call' do
      formatter.emit('implementer', { category: :tool_call, tool: 'Edit', detail: '/foo.rb' })
      expect(io.string).to include('/foo.rb')
    end

    it 'formats Bash tool call' do
      formatter.emit('implementer', { category: :tool_call, tool: 'Bash', detail: 'ls -la' })
      expect(io.string).to include('ls -la')
    end

    it 'formats Read tool call' do
      formatter.emit('reviewer', { category: :tool_call, tool: 'Read', detail: '/bar.rb' })
      expect(io.string).to include('/bar.rb')
    end

    it 'formats Glob tool call' do
      formatter.emit('reviewer', { category: :tool_call, tool: 'Glob', detail: '**/*.rb' })
      expect(io.string).to include('**/*.rb')
    end

    it 'formats unknown tool call' do
      formatter.emit('reviewer', { category: :tool_call, tool: 'WebSearch', detail: '' })
      expect(io.string).to include('WebSearch')
    end

    it 'formats passing test result' do
      formatter.emit('implementer', { category: :tool_result, is_test_result: true, passed: true, command: 'rspec' })
      expect(io.string).to include('PASS')
    end

    it 'formats failing test result' do
      formatter.emit('implementer', { category: :tool_result, is_test_result: true, passed: false, command: 'rspec' })
      expect(io.string).to include('FAIL')
    end

    it 'skips non-test tool results' do
      formatter.emit('implementer', { category: :tool_result, is_test_result: false })
      expect(io.string).to be_empty
    end

    it 'formats blocking text findings' do
      formatter.emit('reviewer', { category: :text, has_findings: true, has_red: true })
      expect(io.string).to include('BLOCKING')
    end

    it 'formats warning text findings' do
      formatter.emit('reviewer', { category: :text, has_findings: true, has_red: false, has_yellow: true })
      expect(io.string).to include('WARNING')
    end

    it 'formats pass text findings' do
      formatter.emit('reviewer', { category: :text, has_findings: true, has_red: false, has_yellow: false })
      expect(io.string).to include('PASS')
    end

    it 'skips text without findings' do
      formatter.emit('reviewer', { category: :text, has_findings: false })
      expect(io.string).to be_empty
    end

    it 'formats success result event' do
      formatter.emit('reviewer', {
                       category: :result, subtype: 'success',
                       cost_usd: 0.05, duration_ms: 10_000, num_turns: 3
                     })
      expect(io.string).to include('DONE')
      expect(io.string).to include('$0.0500')
    end

    it 'formats result with nil costs' do
      formatter.emit('reviewer', {
                       category: :result, subtype: 'error',
                       cost_usd: nil, duration_ms: nil, num_turns: nil
                     })
      expect(io.string).to include('n/a')
    end
  end
end
