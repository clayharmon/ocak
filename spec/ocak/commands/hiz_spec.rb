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

  context 'with --dry-run' do
    it 'prints the pipeline plan without executing' do
      expect { command.call(issue: '42', dry_run: true) }.to output(
        /\[DRY RUN\].*implement.*review.*security/m
      ).to_stdout
    end

    it 'does not create a ClaudeRunner or run agents' do
      allow(claude).to receive(:run_agent)

      command.call(issue: '42', dry_run: true)

      expect(Ocak::ClaudeRunner).not_to have_received(:new)
    end

    it 'includes verify step when test_command is configured' do
      allow(config).to receive(:test_command).and_return('bundle exec rspec')

      expect { command.call(issue: '42', dry_run: true) }.to output(/final-verify/).to_stdout
    end
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

    it 'runs implementer on sonnet, reviewer on haiku, security-reviewer on sonnet' do
      command.call(issue: '42')

      expect(claude).to have_received(:run_agent)
        .with('implementer', 'Implement GitHub issue #42', chdir: '/project', model: 'sonnet')
      expect(claude).to have_received(:run_agent)
        .with('reviewer', 'Review the changes for GitHub issue #42. Run: git diff main',
              chdir: '/project', model: 'haiku')
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

      expect(claude).not_to have_received(:run_agent)
        .with('reviewer', anything, chdir: anything, model: anything)
      expect(claude).not_to have_received(:run_agent)
        .with('security-reviewer', anything, chdir: anything, model: anything)
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
        .with('reviewer', anything, chdir: '/project', model: 'haiku')
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

  context 'when review thread raises an exception' do
    before do
      allow(claude).to receive(:run_agent).and_return(success_result)
      allow(claude).to receive(:run_agent)
        .with('reviewer', anything, chdir: '/project', model: 'haiku')
        .and_raise(StandardError, 'connection reset')
      allow(issues).to receive(:view).with(42).and_return(nil)
      allow(Open3).to receive(:capture3)
        .with('gh', 'pr', 'create', '--title', anything, '--body', anything,
              '--head', anything, chdir: '/project')
        .and_return(["https://github.com/org/repo/pull/1\n", '', success_status])
    end

    it 'logs the error and continues without crashing' do
      command.call(issue: '42')

      expect(logger).to have_received(:error).with(/review thread failed: connection reset/)
      expect(claude).to have_received(:run_agent)
        .with('security-reviewer', anything, chdir: '/project', model: 'sonnet')
    end
  end

  context 'when both review steps run' do
    before do
      allow(claude).to receive(:run_agent).and_return(success_result)
      allow(issues).to receive(:view).with(42).and_return(nil)
      allow(Open3).to receive(:capture3)
        .with('gh', 'pr', 'create', '--title', anything, '--body', anything,
              '--head', anything, chdir: '/project')
        .and_return(["https://github.com/org/repo/pull/1\n", '', success_status])
    end

    it 'invokes both reviewer and security-reviewer' do
      command.call(issue: '42')

      expect(claude).to have_received(:run_agent)
        .with('reviewer', anything, chdir: '/project', model: 'haiku')
      expect(claude).to have_received(:run_agent)
        .with('security-reviewer', anything, chdir: '/project', model: 'sonnet')
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

    it 'wraps verification output in XML tags for prompt injection protection' do
      call_count = 0
      allow(Open3).to receive(:capture3)
        .with('bundle', 'exec', 'rspec', chdir: '/project') do
          call_count += 1
          if call_count == 1
            ['FAIL: some test', 'error', failure_status]
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

      expect(claude).to have_received(:run_agent)
        .with('implementer',
              match(%r{<verification_output>.*FAIL.*</verification_output>}m),
              chdir: '/project', model: 'sonnet')
    end
  end

  context 'when git add fails during commit_changes' do
    before do
      allow(claude).to receive(:run_agent).and_return(success_result)
      allow(Open3).to receive(:capture3)
        .with('git', 'status', '--porcelain', chdir: '/project')
        .and_return(["M file.rb\n", '', success_status])
      allow(Open3).to receive(:capture3)
        .with('git', 'add', '-A', chdir: '/project')
        .and_return(['', 'error: unable to index', failure_status])
    end

    it 'logs a warning and skips commit' do
      command.call(issue: '42')

      expect(logger).to have_received(:warn).with(/git add failed/)
      expect(Open3).not_to have_received(:capture3)
        .with('git', 'commit', '-m', anything, chdir: '/project')
    end
  end

  context 'when git commit fails during commit_changes' do
    before do
      allow(claude).to receive(:run_agent).and_return(success_result)
      allow(Open3).to receive(:capture3)
        .with('git', 'status', '--porcelain', chdir: '/project')
        .and_return(["M file.rb\n", '', success_status])
      allow(Open3).to receive(:capture3)
        .with('git', 'add', '-A', chdir: '/project')
        .and_return(['', '', success_status])
      allow(Open3).to receive(:capture3)
        .with('git', 'commit', '-m', 'feat: implement issue #42 [hiz]', chdir: '/project')
        .and_return(['', 'pre-commit hook failed', failure_status])
      allow(issues).to receive(:view).with(42).and_return(nil)
      allow(Open3).to receive(:capture3)
        .with('gh', 'pr', 'create', '--title', anything, '--body', anything,
              '--head', anything, chdir: '/project')
        .and_return(["https://github.com/org/repo/pull/1\n", '', success_status])
    end

    it 'logs a warning' do
      command.call(issue: '42')

      expect(logger).to have_received(:warn).with(/git commit failed/)
    end
  end

  context 'when cleanup checkout to main fails' do
    before do
      allow(claude).to receive(:run_agent)
        .with('implementer', anything, chdir: '/project', model: 'sonnet')
        .and_return(failure_result)
      allow(Open3).to receive(:capture3)
        .with('git', 'checkout', 'main', chdir: '/project')
        .and_return(['', 'error: pathspec', failure_status])
    end

    it 'logs a warning but does not crash' do
      command.call(issue: '42')

      expect(logger).to have_received(:warn).with(/Cleanup checkout to main failed/)
    end
  end

  describe 'pipeline comments' do
    before do
      allow(claude).to receive(:run_agent).and_return(success_result)
      allow(issues).to receive(:view).with(42).and_return({ 'title' => 'Test', 'number' => 42 })
      allow(Open3).to receive(:capture3)
        .with('gh', 'pr', 'create', '--title', anything, '--body', anything,
              '--head', anything, chdir: '/project')
        .and_return(["https://github.com/org/repo/pull/1\n", '', success_status])
    end

    it 'posts hiz start comment' do
      command.call(issue: '42')

      expect(issues).to have_received(:comment)
        .with(42, /\u{1F680} \*\*Hiz \(fast mode\) started\*\*.*implement.*review.*security/)
    end

    it 'includes verify in start comment when test_command is configured' do
      allow(config).to receive(:test_command).and_return('bundle exec rspec')
      allow(Open3).to receive(:capture3)
        .with('bundle', 'exec', 'rspec', chdir: '/project')
        .and_return(['', '', success_status])

      command.call(issue: '42')

      expect(issues).to have_received(:comment)
        .with(42, /\*\*Hiz \(fast mode\) started\*\*.*verify/)
    end

    it 'posts step start comment for each step' do
      command.call(issue: '42')

      expect(issues).to have_received(:comment)
        .with(42, /\u{1F504} \*\*Phase: implement\*\*/)
      expect(issues).to have_received(:comment)
        .with(42, /\u{1F504} \*\*Phase: review\*\*/)
      expect(issues).to have_received(:comment)
        .with(42, /\u{1F504} \*\*Phase: security\*\*/)
    end

    it 'posts step completion comments' do
      command.call(issue: '42')

      expect(issues).to have_received(:comment)
        .with(42, /\u{2705} \*\*Phase: implement\*\* completed/)
      expect(issues).to have_received(:comment)
        .with(42, /\u{2705} \*\*Phase: review\*\* completed/)
      expect(issues).to have_received(:comment)
        .with(42, /\u{2705} \*\*Phase: security\*\* completed/)
    end

    it 'posts success summary comment' do
      command.call(issue: '42')

      expect(issues).to have_received(:comment)
        .with(42, %r{\u{2705} \*\*Pipeline complete\*\*.*3/3 steps run.*0 skipped})
    end

    it 'posts failure summary when implementation fails' do
      allow(claude).to receive(:run_agent)
        .with('implementer', anything, chdir: '/project', model: 'sonnet')
        .and_return(failure_result)

      command.call(issue: '42')

      expect(issues).to have_received(:comment)
        .with(42, %r{\u{274C} \*\*Pipeline failed\*\* at phase: implement.*1/3 steps completed})
    end

    it 'does not crash when comment posting fails' do
      allow(issues).to receive(:comment).and_raise(StandardError, 'network error')

      expect { command.call(issue: '42') }.not_to raise_error
    end
  end

  describe 'hiz retry comment' do
    before do
      allow(config).to receive(:test_command).and_return('bundle exec rspec')
      allow(claude).to receive(:run_agent).and_return(success_result)
    end

    it 'posts retry warning when final verification fails' do
      allow(Open3).to receive(:capture3)
        .with('bundle', 'exec', 'rspec', chdir: '/project')
        .and_return(['FAIL', '', failure_status])

      command.call(issue: '42')

      expect(issues).to have_received(:comment)
        .with(42, /\u{26A0}.*\*\*Final verification failed\*\*.*attempting auto-fix/)
    end

    it 'posts final-verify start and failure comments' do
      allow(Open3).to receive(:capture3)
        .with('bundle', 'exec', 'rspec', chdir: '/project')
        .and_return(['FAIL', '', failure_status])

      command.call(issue: '42')

      expect(issues).to have_received(:comment)
        .with(42, /\u{1F504} \*\*Phase: final-verify\*\*/)
      expect(issues).to have_received(:comment)
        .with(42, /\u{274C} \*\*Phase: final-verify\*\* failed/)
    end

    it 'posts final-verify completion on success' do
      allow(Open3).to receive(:capture3)
        .with('bundle', 'exec', 'rspec', chdir: '/project')
        .and_return(['', '', success_status])
      allow(issues).to receive(:view).with(42).and_return(nil)
      allow(Open3).to receive(:capture3)
        .with('gh', 'pr', 'create', '--title', anything, '--body', anything,
              '--head', anything, chdir: '/project')
        .and_return(["https://github.com/org/repo/pull/1\n", '', success_status])

      command.call(issue: '42')

      expect(issues).to have_received(:comment)
        .with(42, /\u{2705} \*\*Phase: final-verify\*\* completed/)
    end
  end

  it 'exits with error on ConfigNotFound' do
    allow(Ocak::Config).to receive(:load).and_raise(Ocak::Config::ConfigNotFound, 'not found')

    expect { command.call(issue: '42') }.to raise_error(SystemExit)
  end
end
