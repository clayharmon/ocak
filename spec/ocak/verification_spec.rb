# frozen_string_literal: true

require 'spec_helper'
require 'ocak/verification'

RSpec.describe Ocak::Verification do
  let(:config) do
    instance_double(Ocak::Config,
                    test_command: 'bundle exec rspec',
                    lint_command: 'bundle exec rubocop -A',
                    lint_check_command: 'bundle exec rubocop',
                    language: 'ruby')
  end
  let(:logger) { instance_double(Ocak::PipelineLogger, info: nil, warn: nil, error: nil) }
  let(:chdir) { '/project' }

  let(:host) do
    klass = Class.new do
      include Ocak::Verification

      def initialize(config)
        @config = config
      end
    end
    klass.new(config)
  end

  describe '#run_final_checks' do
    it 'returns success when all checks pass' do
      allow(Open3).to receive(:capture3)
        .with('bundle', 'exec', 'rspec', chdir: chdir)
        .and_return(['ok', '', instance_double(Process::Status, success?: true)])

      allow(Open3).to receive(:capture3)
        .with('git', 'diff', '--name-only', 'main', chdir: chdir)
        .and_return(["lib/ocak/foo.rb\n", '', instance_double(Process::Status, success?: true)])

      allow(Open3).to receive(:capture3)
        .with('bundle', 'exec', 'rubocop', '--force-exclusion', 'lib/ocak/foo.rb', chdir: chdir)
        .and_return(['', '', instance_double(Process::Status, success?: true)])

      result = host.run_final_checks(logger, chdir: chdir)

      expect(result[:success]).to be true
    end

    it 'returns failure with test command on test failure' do
      allow(Open3).to receive(:capture3)
        .with('bundle', 'exec', 'rspec', chdir: chdir)
        .and_return(['3 failures', 'error output', instance_double(Process::Status, success?: false)])

      allow(Open3).to receive(:capture3)
        .with('git', 'diff', '--name-only', 'main', chdir: chdir)
        .and_return(['', '', instance_double(Process::Status, success?: true)])

      result = host.run_final_checks(logger, chdir: chdir)

      expect(result[:success]).to be false
      expect(result[:failures]).to include('bundle exec rspec')
    end

    it 'returns failure when test command has unmatched quotes' do
      allow(config).to receive(:test_command).and_return("bundle exec 'unclosed")
      allow(config).to receive(:lint_check_command).and_return(nil)

      result = host.run_final_checks(logger, chdir: chdir)

      expect(result[:success]).to be false
      expect(result[:failures]).to include("bundle exec 'unclosed")
      expect(logger).to have_received(:warn).with(/Invalid shell command in config/)
    end

    it 'returns success when no test or lint commands configured' do
      allow(config).to receive(:test_command).and_return(nil)
      allow(config).to receive(:lint_check_command).and_return(nil)

      result = host.run_final_checks(logger, chdir: chdir)

      expect(result[:success]).to be true
    end
  end

  describe '#run_scoped_lint' do
    it 'returns nil when no changed files match lint extensions' do
      allow(Open3).to receive(:capture3)
        .with('git', 'diff', '--name-only', 'main', chdir: chdir)
        .and_return(["README.md\n", '', instance_double(Process::Status, success?: true)])

      result = host.run_scoped_lint(logger, chdir: chdir)

      expect(result).to be_nil
    end

    it 'returns nil when lint passes' do
      allow(Open3).to receive(:capture3)
        .with('git', 'diff', '--name-only', 'main', chdir: chdir)
        .and_return(["lib/foo.rb\n", '', instance_double(Process::Status, success?: true)])

      allow(Open3).to receive(:capture3)
        .with('bundle', 'exec', 'rubocop', '--force-exclusion', 'lib/foo.rb', chdir: chdir)
        .and_return(['', '', instance_double(Process::Status, success?: true)])

      result = host.run_scoped_lint(logger, chdir: chdir)

      expect(result).to be_nil
    end

    it 'returns formatted output when lint fails' do
      allow(Open3).to receive(:capture3)
        .with('git', 'diff', '--name-only', 'main', chdir: chdir)
        .and_return(["lib/foo.rb\n", '', instance_double(Process::Status, success?: true)])

      allow(Open3).to receive(:capture3)
        .with('bundle', 'exec', 'rubocop', '--force-exclusion', 'lib/foo.rb', chdir: chdir)
        .and_return(['offenses found', 'stderr', instance_double(Process::Status, success?: false)])

      result = host.run_scoped_lint(logger, chdir: chdir)

      expect(result).to include('bundle exec rubocop')
      expect(result).to include('offenses found')
    end

    it 'returns error string when lint command has unmatched quotes' do
      allow(config).to receive(:lint_check_command).and_return("rubocop 'unclosed")

      allow(Open3).to receive(:capture3)
        .with('git', 'diff', '--name-only', 'main', chdir: chdir)
        .and_return(["lib/foo.rb\n", '', instance_double(Process::Status, success?: true)])

      result = host.run_scoped_lint(logger, chdir: chdir)

      expect(result).to include('ArgumentError')
      expect(logger).to have_received(:warn).with(/Invalid shell command in config/)
    end

    it 'logs and returns nil when no files to lint' do
      allow(Open3).to receive(:capture3)
        .with('git', 'diff', '--name-only', 'main', chdir: chdir)
        .and_return(['', '', instance_double(Process::Status, success?: true)])

      result = host.run_scoped_lint(logger, chdir: chdir)

      expect(result).to be_nil
      expect(logger).to have_received(:info).with('No changed files to lint')
    end
  end

  describe '#run_verification_with_retry' do
    let(:claude) { instance_double(Ocak::ClaudeRunner) }

    it 'returns nil when no commands configured' do
      allow(config).to receive(:test_command).and_return(nil)
      allow(config).to receive(:lint_check_command).and_return(nil)
      comments = []

      result = host.run_verification_with_retry(logger: logger, claude: claude, chdir: chdir) do |body|
        comments << body
      end

      expect(result).to be_nil
      expect(comments).to be_empty
    end

    it 'calls block with start and complete messages on success' do
      allow(Open3).to receive(:capture3)
        .with('bundle', 'exec', 'rspec', chdir: chdir)
        .and_return(['ok', '', instance_double(Process::Status, success?: true)])
      allow(Open3).to receive(:capture3)
        .with('git', 'diff', '--name-only', 'main', chdir: chdir)
        .and_return(['', '', instance_double(Process::Status, success?: true)])
      comments = []

      result = host.run_verification_with_retry(logger: logger, claude: claude, chdir: chdir) do |body|
        comments << body
      end

      expect(result).to be_nil
      expect(comments.size).to eq(2)
      expect(comments[0]).to include('final-verify')
      expect(comments[1]).to include("\u{2705}")
    end

    it 'calls block with warning and fail messages after double failure' do
      allow(Open3).to receive(:capture3)
        .with('bundle', 'exec', 'rspec', chdir: chdir)
        .and_return(['failures', 'err', instance_double(Process::Status, success?: false)])
      allow(Open3).to receive(:capture3)
        .with('git', 'diff', '--name-only', 'main', chdir: chdir)
        .and_return(['', '', instance_double(Process::Status, success?: true)])
      allow(claude).to receive(:run_agent)
      comments = []

      result = host.run_verification_with_retry(logger: logger, claude: claude, chdir: chdir) do |body|
        comments << body
      end

      expect(result).to include(success: false)
      expect(comments.size).to eq(3)
      expect(comments[0]).to include('final-verify')
      expect(comments[1]).to include("\u{26A0}")
      expect(comments[2]).to include("\u{274C}")
    end

    it 'passes model to claude.run_agent when specified' do
      allow(Open3).to receive(:capture3)
        .with('bundle', 'exec', 'rspec', chdir: chdir)
        .and_return(['failures', 'err', instance_double(Process::Status, success?: false)])
      allow(Open3).to receive(:capture3)
        .with('git', 'diff', '--name-only', 'main', chdir: chdir)
        .and_return(['', '', instance_double(Process::Status, success?: true)])
      allow(claude).to receive(:run_agent)

      host.run_verification_with_retry(logger: logger, claude: claude, chdir: chdir,
                                       model: 'us.anthropic.claude-sonnet-4-6-v1') do |body|
        body
      end

      expect(claude).to have_received(:run_agent)
        .with('implementer', anything, chdir: chdir, model: 'us.anthropic.claude-sonnet-4-6-v1')
    end

    it 'does not pass model when nil' do
      allow(Open3).to receive(:capture3)
        .with('bundle', 'exec', 'rspec', chdir: chdir)
        .and_return(['failures', 'err', instance_double(Process::Status, success?: false)])
      allow(Open3).to receive(:capture3)
        .with('git', 'diff', '--name-only', 'main', chdir: chdir)
        .and_return(['', '', instance_double(Process::Status, success?: true)])
      allow(claude).to receive(:run_agent)

      host.run_verification_with_retry(logger: logger, claude: claude, chdir: chdir) { |body| body }

      expect(claude).to have_received(:run_agent)
        .with('implementer', anything, chdir: chdir)
    end
  end

  describe '#lint_extensions_for' do
    it 'returns ruby extensions' do
      expect(host.lint_extensions_for('ruby')).to eq(%w[.rb .rake .gemspec])
    end

    it 'returns typescript extensions' do
      expect(host.lint_extensions_for('typescript')).to eq(%w[.ts .tsx])
    end

    it 'returns javascript extensions' do
      expect(host.lint_extensions_for('javascript')).to eq(%w[.js .jsx])
    end

    it 'returns python extensions' do
      expect(host.lint_extensions_for('python')).to eq(%w[.py])
    end

    it 'returns rust extensions' do
      expect(host.lint_extensions_for('rust')).to eq(%w[.rs])
    end

    it 'returns go extensions' do
      expect(host.lint_extensions_for('go')).to eq(%w[.go])
    end

    it 'returns elixir extensions' do
      expect(host.lint_extensions_for('elixir')).to eq(%w[.ex .exs])
    end

    it 'returns java extensions' do
      expect(host.lint_extensions_for('java')).to eq(%w[.java])
    end

    it 'returns default extensions for unknown language' do
      expect(host.lint_extensions_for('unknown')).to eq(%w[.rb .ts .tsx .js .jsx .py .rs .go])
    end
  end
end
