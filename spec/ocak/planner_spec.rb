# frozen_string_literal: true

require 'spec_helper'
require 'ocak/planner'

RSpec.describe Ocak::Planner do
  let(:host) do
    Class.new { include Ocak::Planner }.new
  end

  describe '#build_step_prompt' do
    it 'returns fix prompt with review output wrapped in XML tags for fix role' do
      prompt = host.build_step_prompt('fix', 42, 'Found bugs')

      expect(prompt).to eq("Fix these review findings for issue #42:\n\n<review_output>\nFound bugs\n</review_output>")
    end

    it 'returns formatted prompt for known roles' do
      prompt = host.build_step_prompt('implement', 7, nil)

      expect(prompt).to eq('Implement GitHub issue #7')
    end

    it 'returns formatted prompt for review role' do
      prompt = host.build_step_prompt('review', 3, nil)

      expect(prompt).to eq('Review the changes for GitHub issue #3. Run: git diff main')
    end

    it 'returns generic prompt for unknown roles' do
      prompt = host.build_step_prompt('custom_step', 99, nil)

      expect(prompt).to eq('Run custom_step for GitHub issue #99')
    end
  end

  describe '#plan_batches' do
    let(:logger) { instance_double(Ocak::PipelineLogger, info: nil, warn: nil, error: nil) }
    let(:claude) { instance_double(Ocak::ClaudeRunner) }

    context 'with a single issue' do
      it 'returns sequential batches without calling claude' do
        issues = [{ 'number' => 1, 'title' => 'Fix bug' }]
        allow(claude).to receive(:run_agent)

        result = host.plan_batches(issues, logger: logger, claude: claude)

        expect(result).to eq([{ 'batch' => 1, 'issues' => [{ 'number' => 1, 'title' => 'Fix bug',
                                                             'complexity' => 'full' }] }])
        expect(claude).not_to have_received(:run_agent)
      end
    end

    context 'with multiple issues' do
      let(:issues) do
        [
          { 'number' => 1, 'title' => 'Fix bug' },
          { 'number' => 2, 'title' => 'Add feature' }
        ]
      end

      it 'calls claude planner and parses batches on success' do
        batch_json = '{"batches": [{"batch": 1, "issues": [{"number": 1}, {"number": 2}]}]}'
        result = Ocak::ClaudeRunner::AgentResult.new(success: true, output: batch_json)

        allow(claude).to receive(:run_agent).with('planner', anything).and_return(result)

        batches = host.plan_batches(issues, logger: logger, claude: claude)

        expect(batches).to eq([{ 'batch' => 1, 'issues' => [{ 'number' => 1 }, { 'number' => 2 }] }])
      end

      it 'falls back to sequential on planner failure' do
        result = Ocak::ClaudeRunner::AgentResult.new(success: false, output: 'error')

        allow(claude).to receive(:run_agent).with('planner', anything).and_return(result)

        batches = host.plan_batches(issues, logger: logger, claude: claude)

        expect(batches.size).to eq(2)
        expect(batches[0]['batch']).to eq(1)
        expect(batches[1]['batch']).to eq(2)
      end
    end
  end

  describe '#parse_planner_output' do
    let(:logger) { instance_double(Ocak::PipelineLogger, info: nil, warn: nil, error: nil) }
    let(:issues) { [{ 'number' => 1, 'title' => 'A' }] }

    it 'parses valid JSON with batches key' do
      output = 'Here are the batches: {"batches": [{"batch": 1, "issues": [1]}]}'

      result = host.parse_planner_output(output, issues, logger)

      expect(result).to eq([{ 'batch' => 1, 'issues' => [1] }])
    end

    it 'falls back to sequential on missing batches key' do
      output = 'No JSON here at all'

      result = host.parse_planner_output(output, issues, logger)

      expect(result.size).to eq(1)
      expect(result[0]['batch']).to eq(1)
      expect(logger).to have_received(:warn).with(/Could not parse/)
    end

    it 'falls back to sequential on malformed JSON' do
      output = '{"batches": [invalid json}'

      result = host.parse_planner_output(output, issues, logger)

      expect(result.size).to eq(1)
      expect(logger).to have_received(:warn).with(/JSON parse error/)
    end
  end

  describe '#sequential_batches' do
    it 'wraps each issue in its own batch' do
      issues = [
        { 'number' => 1, 'title' => 'A' },
        { 'number' => 2, 'title' => 'B' }
      ]

      result = host.sequential_batches(issues)

      expect(result.size).to eq(2)
      expect(result[0]).to eq({ 'batch' => 1, 'issues' => [{ 'number' => 1, 'title' => 'A',
                                                             'complexity' => 'full' }] })
      expect(result[1]).to eq({ 'batch' => 2, 'issues' => [{ 'number' => 2, 'title' => 'B',
                                                             'complexity' => 'full' }] })
    end

    it 'preserves existing complexity' do
      issues = [{ 'number' => 1, 'title' => 'A', 'complexity' => 'simple' }]

      result = host.sequential_batches(issues)

      expect(result[0]['issues'][0]['complexity']).to eq('simple')
    end

    it 'returns empty array for empty input' do
      expect(host.sequential_batches([]).size).to eq(0)
    end
  end
end
