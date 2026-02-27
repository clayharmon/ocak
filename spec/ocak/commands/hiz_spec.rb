# frozen_string_literal: true

require 'spec_helper'
require 'dry/cli'
require 'ocak/commands/hiz'

RSpec.describe Ocak::Commands::Hiz do
  subject(:command) { described_class.new }

  let(:config) do
    instance_double(Ocak::Config,
                    project_dir: '/project',
                    log_dir: 'logs/pipeline',
                    test_command: nil,
                    lint_command: nil,
                    lint_check_command: nil,
                    language: 'ruby')
  end

  let(:logger) { instance_double(Ocak::PipelineLogger, info: nil, warn: nil, error: nil, log_file_path: nil) }
  let(:claude) { instance_double(Ocak::ClaudeRunner) }
  let(:issues) { instance_double(Ocak::IssueFetcher, comment: nil, view: nil) }
  let(:success_result) { Ocak::ClaudeRunner::AgentResult.new(success: true, output: 'Done') }
  let(:failure_result) { Ocak::ClaudeRunner::AgentResult.new(success: false, output: 'Error') }
  let(:success_status) { instance_double(Process::Status, success?: true) }
  let(:failure_status) { instance_double(Process::Status, success?: false) }

  before do
    allow(Ocak::Config).to receive(:load).and_return(config)
    allow(Ocak::PipelineLogger).to receive(:new).and_return(logger)
    allow(Ocak::ClaudeRunner).to receive(:new).and_return(claude)
    allow(Ocak::IssueFetcher).to receive(:new).and_return(issues)
    # Default: all git/gh commands succeed
    allow(Open3).to receive(:capture3).and_return(['', '', success_status])
  end

  context 'when pipeline succeeds' do
    before do
      allow(claude).to receive(:run_agent).and_return(success_result)
      allow(issues).to receive(:view).with(42).and_return({ 'title' => 'Add fast mode', 'number' => 42 })
      allow(Open3).to receive(:capture3)
        .with('gh', 'pr', 'create', '--title', anything, '--body', anything,
              '--head', anything, chdir: '/project')
        .and_return(["https://github.com/org/repo/pull/1\n", '', success_status])
    end

    it 'runs all three agents with sonnet model' do
      command.call(issue: '42')

      expect(claude).to have_received(:run_agent)
        .with('implementer', 'Implement GitHub issue #42', chdir: '/project', model: 'sonnet')
      expect(claude).to have_received(:run_agent)
        .with('reviewer', 'Review the changes for GitHub issue #42. Run: git diff main',
              chdir: '/project', model: 'sonnet')
      expect(claude).to have_received(:run_agent)
        .with('security-reviewer', 'Security review changes for GitHub issue #42. Run: git diff main',
              chdir: '/project', model: 'sonnet')
    end

    it 'creates a branch with hiz/ prefix' do
      command.call(issue: '42')

      expect(Open3).to have_received(:capture3)
        .with('git', 'checkout', '-b', match(%r{\Ahiz/issue-42-[0-9a-f]{8}\z}), chdir: '/project')
    end

    it 'creates a PR via gh with issue title' do
      command.call(issue: '42')

      expect(Open3).to have_received(:capture3)
        .with('gh', 'pr', 'create',
              '--title', 'Fix #42: Add fast mode',
              '--body', match(/Closes #42/),
              '--head', match(%r{\Ahiz/issue-42-}),
              chdir: '/project')
    end

    it 'prints the PR URL' do
      expect { command.call(issue: '42') }.to output(/PR created: https:/).to_stdout
    end
  end

  context 'when implementation fails' do
    before do
      allow(claude).to receive(:run_agent)
        .with('implementer', anything, chdir: '/project', model: 'sonnet')
        .and_return(failure_result)
    end

    it 'stops pipeline and comments on issue' do
      command.call(issue: '42')

      expect(issues).to have_received(:comment).with(42, match(/failed at phase: implement/))
    end

    it 'does not call reviewer or security' do
      command.call(issue: '42')

      expect(claude).not_to have_received(:run_agent).with('reviewer', anything, anything)
      expect(claude).not_to have_received(:run_agent).with('security-reviewer', anything, anything)
    end

    it 'checks out main to restore clean state' do
      command.call(issue: '42')

      expect(Open3).to have_received(:capture3)
        .with('git', 'checkout', 'main', chdir: '/project')
    end
  end

  context 'when review fails but implementation succeeds' do
    before do
      allow(claude).to receive(:run_agent).and_return(success_result)
      allow(claude).to receive(:run_agent)
        .with('reviewer', anything, chdir: '/project', model: 'sonnet')
        .and_return(failure_result)
      allow(issues).to receive(:view).with(42).and_return(nil)
      allow(Open3).to receive(:capture3)
        .with('gh', 'pr', 'create', '--title', anything, '--body', anything,
              '--head', anything, chdir: '/project')
        .and_return(["https://github.com/org/repo/pull/1\n", '', success_status])
    end

    it 'continues to security review' do
      command.call(issue: '42')

      expect(claude).to have_received(:run_agent)
        .with('security-reviewer', anything, chdir: '/project', model: 'sonnet')
    end

    it 'still creates a PR' do
      command.call(issue: '42')

      expect(Open3).to have_received(:capture3)
        .with('gh', 'pr', 'create', '--title', anything, '--body', anything,
              '--head', anything, chdir: '/project')
    end
  end

  context 'when issue title is unavailable' do
    before do
      allow(claude).to receive(:run_agent).and_return(success_result)
      allow(issues).to receive(:view).with(42).and_return(nil)
      allow(Open3).to receive(:capture3)
        .with('gh', 'pr', 'create', '--title', anything, '--body', anything,
              '--head', anything, chdir: '/project')
        .and_return(["https://github.com/org/repo/pull/1\n", '', success_status])
    end

    it 'falls back to basic PR title' do
      command.call(issue: '42')

      expect(Open3).to have_received(:capture3)
        .with('gh', 'pr', 'create',
              '--title', 'Fix #42',
              '--body', anything,
              '--head', anything,
              chdir: '/project')
    end
  end

  context 'when push fails' do
    before do
      allow(claude).to receive(:run_agent).and_return(success_result)
      allow(Open3).to receive(:capture3)
        .with('git', 'push', '-u', 'origin', anything, chdir: '/project')
        .and_return(['', 'remote rejected', failure_status])
    end

    it 'comments on the issue and checks out main' do
      command.call(issue: '42')

      expect(issues).to have_received(:comment).with(42, match(/failed at phase: push/))
      expect(Open3).to have_received(:capture3)
        .with('git', 'checkout', 'main', chdir: '/project')
    end
  end

  context 'with final verification' do
    before do
      allow(config).to receive(:test_command).and_return('bundle exec rspec')
      allow(claude).to receive(:run_agent).and_return(success_result)
    end

    it 'runs final checks when test_command is configured' do
      allow(Open3).to receive(:capture3)
        .with('bundle', 'exec', 'rspec', chdir: '/project')
        .and_return(['', '', success_status])
      allow(issues).to receive(:view).with(42).and_return(nil)
      allow(Open3).to receive(:capture3)
        .with('gh', 'pr', 'create', '--title', anything, '--body', anything,
              '--head', anything, chdir: '/project')
        .and_return(["https://github.com/org/repo/pull/1\n", '', success_status])

      command.call(issue: '42')

      expect(Open3).to have_received(:capture3)
        .with('bundle', 'exec', 'rspec', chdir: '/project')
    end

    it 'attempts fix when final checks fail then pass' do
      call_count = 0
      allow(Open3).to receive(:capture3)
        .with('bundle', 'exec', 'rspec', chdir: '/project') do
          call_count += 1
          if call_count == 1
            ['FAIL', 'error', failure_status]
          else
            ['', '', success_status]
          end
        end
      allow(issues).to receive(:view).with(42).and_return(nil)
      allow(Open3).to receive(:capture3)
        .with('gh', 'pr', 'create', '--title', anything, '--body', anything,
              '--head', anything, chdir: '/project')
        .and_return(["https://github.com/org/repo/pull/1\n", '', success_status])

      command.call(issue: '42')

      # Fix attempt with sonnet
      expect(claude).to have_received(:run_agent)
        .with('implementer', match(%r{Fix these test/lint failures}), chdir: '/project', model: 'sonnet')
    end
  end

  it 'exits with error on ConfigNotFound' do
    allow(Ocak::Config).to receive(:load).and_raise(Ocak::Config::ConfigNotFound, 'not found')

    expect { command.call(issue: '42') }.to raise_error(SystemExit)
  end
end
