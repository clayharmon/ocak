# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Ocak::ClaudeRunner do
  let(:dir) { Dir.mktmpdir }
  let(:config) do
    instance_double(Ocak::Config,
                    project_dir: dir,
                    agent_path: File.join(dir, '.claude', 'agents', 'reviewer.md'))
  end
  let(:logger) { instance_double(Ocak::PipelineLogger, info: nil, warn: nil, error: nil) }

  subject(:runner) { described_class.new(config: config, logger: logger) }

  after { FileUtils.remove_entry(dir) }

  describe '#run_agent' do
    it 'returns failure when agent file does not exist' do
      result = runner.run_agent('reviewer', 'Review code')

      expect(result.success?).to be false
      expect(result.output).to include('Agent file not found')
    end

    context 'with agent file present' do
      before do
        agent_dir = File.join(dir, '.claude', 'agents')
        FileUtils.mkdir_p(agent_dir)
        File.write(File.join(agent_dir, 'reviewer.md'), '# Reviewer Agent')
      end

      it 'invokes ProcessRunner with correct command' do
        result_json = JSON.generate(type: 'result', subtype: 'success', result: 'All good',
                                    total_cost_usd: 0.01, duration_ms: 5000, num_turns: 2)

        allow(Ocak::ProcessRunner).to receive(:run) do |cmd, **opts|
          expect(cmd).to include('claude', '-p')
          expect(cmd).to include('--allowedTools')
          # Simulate streaming: call on_line with the result JSON
          opts[:on_line]&.call(result_json)
          [result_json, '', instance_double(Process::Status, success?: true)]
        end

        result = runner.run_agent('reviewer', 'Review code')
        expect(result.success?).to be true
        expect(result.output).to eq('All good')
      end

      it 'reports failure when process exits non-zero' do
        allow(Ocak::ProcessRunner).to receive(:run)
          .and_return(['', 'error occurred', instance_double(Process::Status, success?: false)])

        result = runner.run_agent('reviewer', 'Review code')
        expect(result.success?).to be false
      end

      it 'uses default tools for unknown agent names' do
        allow(config).to receive(:agent_path).with('custom-agent')
                                             .and_return(File.join(dir, '.claude', 'agents', 'reviewer.md'))

        allow(Ocak::ProcessRunner).to receive(:run) do |cmd, **_opts|
          tools_idx = cmd.index('--allowedTools')
          expect(cmd[tools_idx + 1]).to eq('Read,Glob,Grep,Bash')
          ['', '', instance_double(Process::Status, success?: false)]
        end

        runner.run_agent('custom-agent', 'Do something')
      end
    end
  end

  describe '#run_prompt' do
    it 'extracts result from stream-json output' do
      stream_output = [
        JSON.generate(type: 'system', subtype: 'init', model: 'claude-4'),
        JSON.generate(type: 'result', subtype: 'success', result: 'extracted text')
      ].join("\n")

      allow(Ocak::ProcessRunner).to receive(:run)
        .and_return([stream_output, '', instance_double(Process::Status, success?: true)])

      result = runner.run_prompt('Analyze this')
      expect(result.success?).to be true
      expect(result.output).to eq('extracted text')
    end

    it 'falls back to raw stdout when no result event found' do
      allow(Ocak::ProcessRunner).to receive(:run)
        .and_return(['raw output', '', instance_double(Process::Status, success?: true)])

      result = runner.run_prompt('Analyze this')
      expect(result.output).to eq('raw output')
    end

    it 'reports failure on non-zero exit' do
      allow(Ocak::ProcessRunner).to receive(:run)
        .and_return(['', 'error', Ocak::ClaudeRunner::FailedStatus.instance])

      result = runner.run_prompt('Analyze this')
      expect(result.success?).to be false
    end
  end

  describe 'AgentResult' do
    it 'reports blocking findings' do
      result = described_class::AgentResult.new(success: true, output: "Found \u{1F534} issue")
      expect(result.blocking_findings?).to be true
      expect(result.warnings?).to be false
    end

    it 'reports warnings' do
      result = described_class::AgentResult.new(success: true, output: "Minor \u{1F7E1} warning")
      expect(result.warnings?).to be true
      expect(result.blocking_findings?).to be false
    end

    it 'handles nil output' do
      result = described_class::AgentResult.new(success: true, output: nil)
      expect(result.blocking_findings?).to be false
      expect(result.warnings?).to be false
    end
  end

  describe 'FailedStatus' do
    it 'reports not success' do
      expect(described_class::FailedStatus.instance.success?).to be false
    end
  end
end
