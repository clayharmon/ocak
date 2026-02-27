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

    it 'logs and returns nil when no files to lint' do
      allow(Open3).to receive(:capture3)
        .with('git', 'diff', '--name-only', 'main', chdir: chdir)
        .and_return(['', '', instance_double(Process::Status, success?: true)])

      result = host.run_scoped_lint(logger, chdir: chdir)

      expect(result).to be_nil
      expect(logger).to have_received(:info).with('No changed files to lint')
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
