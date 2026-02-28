# frozen_string_literal: true

require 'spec_helper'
require 'ocak/run_report'
require 'tmpdir'

RSpec.describe Ocak::RunReport do
  let(:dir) { Dir.mktmpdir }

  subject(:report) { described_class.new(complexity: 'full') }

  after { FileUtils.remove_entry(dir) }

  describe '#record_step' do
    it 'records a completed step with all metrics' do
      result = Ocak::ClaudeRunner::AgentResult.new(
        success: true, output: 'Done', cost_usd: 0.38,
        duration_ms: 142_000, num_turns: 12, files_edited: ['lib/foo.rb', 'spec/foo_spec.rb']
      )

      report.record_step(index: 0, agent: 'implementer', role: 'implement', status: 'completed', result: result)

      step = report.steps.first
      expect(step[:index]).to eq(0)
      expect(step[:agent]).to eq('implementer')
      expect(step[:role]).to eq('implement')
      expect(step[:status]).to eq('completed')
      expect(step[:duration_s]).to eq(142)
      expect(step[:cost_usd]).to eq(0.38)
      expect(step[:num_turns]).to eq(12)
      expect(step[:files_edited]).to eq(['lib/foo.rb', 'spec/foo_spec.rb'])
    end

    it 'records a skipped step with reason' do
      report.record_step(index: 2, agent: 'security-reviewer', role: 'security',
                         status: 'skipped', skip_reason: 'fast-track issue (simple complexity)')

      step = report.steps.first
      expect(step[:index]).to eq(2)
      expect(step[:agent]).to eq('security-reviewer')
      expect(step[:status]).to eq('skipped')
      expect(step[:skip_reason]).to eq('fast-track issue (simple complexity)')
      expect(step).not_to have_key(:duration_s)
    end

    it 'handles result with nil metrics' do
      result = Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Done')

      report.record_step(index: 0, agent: 'implementer', role: 'implement', status: 'completed', result: result)

      step = report.steps.first
      expect(step[:duration_s]).to eq(0)
      expect(step[:cost_usd]).to eq(0.0)
      expect(step[:num_turns]).to eq(0)
      expect(step[:files_edited]).to eq([])
    end
  end

  describe '#finish' do
    it 'sets success and finished_at' do
      report.finish(success: true)

      expect(report.success).to be true
      expect(report.finished_at).not_to be_nil
      expect(report.failed_phase).to be_nil
    end

    it 'sets failed_phase on failure' do
      report.finish(success: false, failed_phase: 'implement')

      expect(report.success).to be false
      expect(report.failed_phase).to eq('implement')
    end
  end

  describe '#save' do
    it 'writes valid JSON to the correct directory' do
      report.finish(success: true)

      path = report.save(42, project_dir: dir)

      expect(File.exist?(path)).to be true
      expect(path).to match(%r{\.ocak/reports/issue-42-\d+\.json$})

      data = JSON.parse(File.read(path), symbolize_names: true)
      expect(data[:issue_number]).to eq(42)
      expect(data[:success]).to be true
      expect(data[:complexity]).to eq('full')
    end

    it 'creates the reports directory if missing' do
      report.finish(success: true)
      path = report.save(42, project_dir: dir)

      expect(Dir.exist?(File.dirname(path))).to be true
    end

    it 'includes step data in the saved JSON' do
      result = Ocak::ClaudeRunner::AgentResult.new(
        success: true, output: 'Done', cost_usd: 0.10, duration_ms: 30_000, num_turns: 5, files_edited: []
      )
      report.record_step(index: 0, agent: 'implementer', role: 'implement', status: 'completed', result: result)
      report.record_step(index: 1, agent: 'reviewer', role: 'review', status: 'skipped',
                         skip_reason: 'no blocking findings')
      report.finish(success: true)

      path = report.save(42, project_dir: dir)
      data = JSON.parse(File.read(path), symbolize_names: true)

      expect(data[:steps].size).to eq(2)
      expect(data[:steps][0][:agent]).to eq('implementer')
      expect(data[:steps][1][:status]).to eq('skipped')
      expect(data[:total_cost_usd]).to eq(0.1)
    end

    it 'computes total_duration_s from timestamps' do
      report.finish(success: true)
      path = report.save(42, project_dir: dir)

      data = JSON.parse(File.read(path), symbolize_names: true)
      expect(data[:total_duration_s]).to be_a(Integer)
      expect(data[:total_duration_s]).to be >= 0
    end
  end

  describe '#to_h' do
    it 'includes all report fields' do
      report.finish(success: false, failed_phase: 'review')
      hash = report.to_h(42)

      expect(hash).to include(
        issue_number: 42,
        complexity: 'full',
        success: false,
        failed_phase: 'review'
      )
      expect(hash).to have_key(:started_at)
      expect(hash).to have_key(:finished_at)
      expect(hash).to have_key(:total_duration_s)
      expect(hash).to have_key(:total_cost_usd)
      expect(hash).to have_key(:steps)
    end
  end

  describe '.load_all' do
    it 'loads all report files from the reports directory' do
      reports_dir = File.join(dir, '.ocak', 'reports')
      FileUtils.mkdir_p(reports_dir)

      File.write(File.join(reports_dir, 'issue-1-20260228100000.json'),
                 JSON.generate(issue_number: 1, success: true, steps: []))
      File.write(File.join(reports_dir, 'issue-2-20260228110000.json'),
                 JSON.generate(issue_number: 2, success: false, steps: []))

      reports = described_class.load_all(project_dir: dir)

      expect(reports.size).to eq(2)
      expect(reports.map { |r| r[:issue_number] }).to contain_exactly(1, 2)
    end

    it 'returns empty array when directory does not exist' do
      reports = described_class.load_all(project_dir: dir)

      expect(reports).to eq([])
    end

    it 'skips malformed JSON files with a warning' do
      reports_dir = File.join(dir, '.ocak', 'reports')
      FileUtils.mkdir_p(reports_dir)

      File.write(File.join(reports_dir, 'issue-1-20260228100000.json'),
                 JSON.generate(issue_number: 1, success: true, steps: []))
      File.write(File.join(reports_dir, 'issue-2-20260228110000.json'), 'not valid json{{{')

      reports = nil
      expect { reports = described_class.load_all(project_dir: dir) }
        .to output(/Skipping malformed report/).to_stderr

      expect(reports.size).to eq(1)
      expect(reports.first[:issue_number]).to eq(1)
    end

    it 'returns empty array when directory is empty' do
      reports_dir = File.join(dir, '.ocak', 'reports')
      FileUtils.mkdir_p(reports_dir)

      reports = described_class.load_all(project_dir: dir)

      expect(reports).to eq([])
    end
  end
end
