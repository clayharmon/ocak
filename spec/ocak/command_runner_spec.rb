# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Ocak::CommandRunner do
  # Create a test class that includes the module
  let(:test_class) do
    Class.new do
      include Ocak::CommandRunner

      # Make private methods public for testing
      public :run_git, :run_gh, :run_command
    end
  end

  let(:runner) { test_class.new }
  let(:success_status) { instance_double(Process::Status, success?: true) }
  let(:failure_status) { instance_double(Process::Status, success?: false) }

  describe Ocak::CommandRunner::CommandResult do
    describe '#success?' do
      it 'returns true when status is successful' do
        result = described_class.new('output', '', success_status)
        expect(result.success?).to be true
      end

      it 'returns false when status is failed' do
        result = described_class.new('output', 'error', failure_status)
        expect(result.success?).to be false
      end

      it 'returns false when status is nil (command not found)' do
        result = described_class.new('', 'No such file or directory - git', nil)
        expect(result.success?).to be false
      end
    end

    describe '#output' do
      it 'strips whitespace from stdout' do
        result = described_class.new("  output\n  ", '', success_status)
        expect(result.output).to eq('output')
      end

      it 'returns empty string when stdout is empty' do
        result = described_class.new('', '', success_status)
        expect(result.output).to eq('')
      end
    end

    describe '#error' do
      it 'truncates stderr to 500 characters' do
        long_error = 'x' * 1000
        result = described_class.new('', long_error, failure_status)
        expect(result.error).to eq('x' * 500)
        expect(result.error.length).to eq(500)
      end

      it 'returns full stderr when under 500 characters' do
        short_error = 'error message'
        result = described_class.new('', short_error, failure_status)
        expect(result.error).to eq(short_error)
      end
    end
  end

  describe '#run_git' do
    context 'when command succeeds' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'status', '--porcelain', chdir: '/project')
          .and_return(['M  file.rb', '', success_status])
      end

      it 'returns a successful CommandResult' do
        result = runner.run_git('status', '--porcelain', chdir: '/project')

        expect(result).to be_a(Ocak::CommandRunner::CommandResult)
        expect(result.success?).to be true
        expect(result.stdout).to eq('M  file.rb')
        expect(result.output).to eq('M  file.rb')
      end
    end

    context 'when command fails' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'add', '-A', chdir: '/project')
          .and_return(['', 'fatal: not a git repository', failure_status])
      end

      it 'returns a failed CommandResult' do
        result = runner.run_git('add', '-A', chdir: '/project')

        expect(result).to be_a(Ocak::CommandRunner::CommandResult)
        expect(result.success?).to be false
        expect(result.stderr).to eq('fatal: not a git repository')
        expect(result.error).to eq('fatal: not a git repository')
      end
    end

    context 'when command is not found (Errno::ENOENT)' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'status', chdir: '/project')
          .and_raise(Errno::ENOENT, 'git')
      end

      it 'returns a failed CommandResult with error message' do
        result = runner.run_git('status', chdir: '/project')

        expect(result).to be_a(Ocak::CommandRunner::CommandResult)
        expect(result.success?).to be false
        expect(result.status).to be_nil
        expect(result.stderr).to include('No such file or directory')
      end
    end

    context 'without chdir option' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'log', '--oneline')
          .and_return(['abc123 commit', '', success_status])
      end

      it 'runs command in current directory' do
        result = runner.run_git('log', '--oneline')

        expect(result.success?).to be true
        expect(result.stdout).to eq('abc123 commit')
      end
    end
  end

  describe '#run_gh' do
    context 'when command succeeds' do
      before do
        allow(Open3).to receive(:capture3)
          .with('gh', 'issue', 'view', '42', '--json', 'title', chdir: '/project')
          .and_return(['{"title":"Test"}', '', success_status])
      end

      it 'returns a successful CommandResult' do
        result = runner.run_gh('issue', 'view', '42', '--json', 'title', chdir: '/project')

        expect(result).to be_a(Ocak::CommandRunner::CommandResult)
        expect(result.success?).to be true
        expect(result.stdout).to eq('{"title":"Test"}')
      end
    end

    context 'when command fails' do
      before do
        allow(Open3).to receive(:capture3)
          .with('gh', 'issue', 'view', '999', chdir: '/project')
          .and_return(['', 'issue not found', failure_status])
      end

      it 'returns a failed CommandResult' do
        result = runner.run_gh('issue', 'view', '999', chdir: '/project')

        expect(result).to be_a(Ocak::CommandRunner::CommandResult)
        expect(result.success?).to be false
        expect(result.stderr).to eq('issue not found')
      end
    end

    context 'when command is not found (Errno::ENOENT)' do
      before do
        allow(Open3).to receive(:capture3)
          .with('gh', 'issue', 'list')
          .and_raise(Errno::ENOENT, 'gh')
      end

      it 'returns a failed CommandResult with error message' do
        result = runner.run_gh('issue', 'list')

        expect(result).to be_a(Ocak::CommandRunner::CommandResult)
        expect(result.success?).to be false
        expect(result.status).to be_nil
        expect(result.stderr).to include('No such file or directory')
      end
    end

    context 'without chdir option' do
      before do
        allow(Open3).to receive(:capture3)
          .with('gh', 'auth', 'status')
          .and_return(['Logged in', '', success_status])
      end

      it 'runs command in current directory' do
        result = runner.run_gh('auth', 'status')

        expect(result.success?).to be true
        expect(result.stdout).to eq('Logged in')
      end
    end
  end

  describe '#run_command' do
    it 'forwards all arguments to Open3.capture3' do
      allow(Open3).to receive(:capture3)
        .with('echo', 'hello', 'world', chdir: '/tmp')
        .and_return(['hello world', '', success_status])

      result = runner.run_command('echo', 'hello', 'world', chdir: '/tmp')

      expect(result.success?).to be true
      expect(result.stdout).to eq('hello world')
    end

    it 'omits chdir option when not provided' do
      allow(Open3).to receive(:capture3)
        .with('pwd')
        .and_return(['/current/dir', '', success_status])

      result = runner.run_command('pwd')

      expect(result.success?).to be true
    end
  end
end
