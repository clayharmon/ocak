# frozen_string_literal: true

require 'spec_helper'
require 'dry/cli'
require 'tmpdir'
require 'ocak/commands/status'

RSpec.describe Ocak::Commands::Status do
  subject(:command) { described_class.new }

  let(:dir) { Dir.mktmpdir }
  let(:config) do
    instance_double(Ocak::Config,
                    project_dir: dir,
                    worktree_dir: '.claude/worktrees',
                    log_dir: 'logs/pipeline',
                    label_ready: 'auto-ready',
                    label_in_progress: 'in-progress',
                    label_completed: 'completed',
                    label_failed: 'pipeline-failed')
  end

  let(:manager) { instance_double(Ocak::WorktreeManager) }

  before do
    allow(Ocak::Config).to receive(:load).and_return(config)
    allow(Ocak::WorktreeManager).to receive(:new).and_return(manager)
    allow(manager).to receive(:list).and_return([])

    # Mock gh issue list for all labels
    allow(Open3).to receive(:capture3) do |*args, **_kwargs|
      if args.include?('gh')
        ['[]', '', instance_double(Process::Status, success?: true)]
      else
        ['', '', instance_double(Process::Status, success?: true)]
      end
    end
  end

  after { FileUtils.remove_entry(dir) }

  it 'displays pipeline status header' do
    expect { command.call }.to output(/Pipeline Status/).to_stdout
  end

  it 'displays issue counts per label' do
    allow(Open3).to receive(:capture3)
      .with('gh', 'issue', 'list', '--label', 'auto-ready', '--state', 'open',
            '--json', 'number', '--limit', '100', chdir: dir)
      .and_return(['[{"number":1},{"number":2}]', '', instance_double(Process::Status, success?: true)])

    expect { command.call }.to output(/ready: 2/).to_stdout
  end

  it 'displays worktrees' do
    allow(manager).to receive(:list).and_return([
                                                  { path: '/project/.claude/worktrees/issue-1',
                                                    branch: 'auto/issue-1-abc' }
                                                ])

    expect { command.call }.to output(%r{auto/issue-1-abc}).to_stdout
  end

  it 'displays recent logs' do
    log_dir = File.join(dir, 'logs', 'pipeline')
    FileUtils.mkdir_p(log_dir)
    File.write(File.join(log_dir, 'issue-1.log'), 'x' * 100)

    expect { command.call }.to output(/issue-1\.log/).to_stdout
  end

  it 'shows no active worktrees message when empty' do
    expect { command.call }.to output(/No active pipeline worktrees/).to_stdout
  end

  it 'exits with error on ConfigNotFound' do
    allow(Ocak::Config).to receive(:load).and_raise(Ocak::Config::ConfigNotFound, 'not found')

    expect { command.call }.to raise_error(SystemExit)
  end

  describe '--report flag' do
    let(:reports_dir) { File.join(dir, '.ocak', 'reports') }

    def write_report(filename, data)
      FileUtils.mkdir_p(reports_dir)
      File.write(File.join(reports_dir, filename), JSON.generate(data))
    end

    it 'shows recent runs when --report is passed' do
      write_report('issue-42-20260228103000.json',
                   issue_number: 42, success: true,
                   started_at: '2026-02-28T10:30:00Z', finished_at: '2026-02-28T10:35:42Z',
                   total_duration_s: 342, total_cost_usd: 0.84,
                   steps: [
                     { index: 0, agent: 'implementer', role: 'implement',
                       status: 'completed', duration_s: 142, cost_usd: 0.38 },
                     { index: 1, agent: 'reviewer', role: 'review',
                       status: 'completed', duration_s: 45, cost_usd: 0.09 }
                   ],
                   failed_phase: nil)

      expect { command.call(report: true) }.to output(/Recent Runs.*#42.*342s.*\$0\.84/m).to_stdout
    end

    it 'shows aggregate statistics' do
      write_report('issue-1-20260228100000.json',
                   issue_number: 1, success: true,
                   started_at: '2026-02-28T10:00:00Z', total_duration_s: 200, total_cost_usd: 0.50,
                   steps: [{ index: 0, agent: 'implementer', role: 'implement',
                             status: 'completed', duration_s: 200, cost_usd: 0.50 }],
                   failed_phase: nil)
      write_report('issue-2-20260228110000.json',
                   issue_number: 2, success: false,
                   started_at: '2026-02-28T11:00:00Z', total_duration_s: 300, total_cost_usd: 0.70,
                   steps: [{ index: 0, agent: 'implementer', role: 'implement',
                             status: 'completed', duration_s: 300, cost_usd: 0.70 }],
                   failed_phase: 'review')

      output = capture_stdout { command.call(report: true) }

      expect(output).to include('Aggregates (last 2 runs)')
      expect(output).to match(/Avg cost:\s+\$0\.60/)
      expect(output).to match(/Avg duration:\s+250s/)
      expect(output).to match(/Success rate:\s+50%/)
      expect(output).to match(/Slowest step:\s+implement/)
    end

    it 'handles empty reports directory' do
      FileUtils.mkdir_p(reports_dir)

      expect { command.call(report: true) }.to output(/No run reports found/).to_stdout
    end

    it 'handles missing reports directory' do
      expect { command.call(report: true) }.to output(/No run reports found/).to_stdout
    end

    it 'skips malformed JSON files with a warning' do
      write_report('issue-1-20260228100000.json',
                   issue_number: 1, success: true,
                   started_at: '2026-02-28T10:00:00Z', total_duration_s: 100, total_cost_usd: 0.50,
                   steps: [{ index: 0, agent: 'implementer', role: 'implement',
                             status: 'completed', duration_s: 100, cost_usd: 0.50 }],
                   failed_phase: nil)
      File.write(File.join(reports_dir, 'issue-2-20260228110000.json'), 'broken{{{json')

      expect { command.call(report: true) }.to output(/Recent Runs.*#1/m).to_stdout
    end

    it 'does not show reports in default mode' do
      write_report('issue-42-20260228103000.json',
                   issue_number: 42, success: true, steps: [])

      expect { command.call }.to output(/Pipeline Status/).to_stdout
      expect { command.call }.not_to output(/Recent Runs/).to_stdout
    end

    it 'shows failed phase for failed runs' do
      write_report('issue-39-20260228091500.json',
                   issue_number: 39, success: false,
                   started_at: '2026-02-28T09:15:00Z', total_duration_s: 128, total_cost_usd: 0.31,
                   steps: [{ index: 0, agent: 'implementer', role: 'implement',
                             status: 'completed', duration_s: 128, cost_usd: 0.31 }],
                   failed_phase: 'review')

      expect { command.call(report: true) }.to output(/\(failed: review\)/).to_stdout
    end

    it 'shows most skipped step' do
      write_report('issue-1-20260228100000.json',
                   issue_number: 1, success: true,
                   started_at: '2026-02-28T10:00:00Z', total_duration_s: 100, total_cost_usd: 0.50,
                   steps: [
                     { index: 0, agent: 'implementer', role: 'implement',
                       status: 'completed', duration_s: 100, cost_usd: 0.50 },
                     { index: 1, agent: 'security-reviewer', role: 'security',
                       status: 'skipped', skip_reason: 'fast-track' }
                   ],
                   failed_phase: nil)

      expect { command.call(report: true) }.to output(/Most skipped:.*security/).to_stdout
    end
  end

  private

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
