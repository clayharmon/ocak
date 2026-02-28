# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Ocak::GitUtils do
  let(:success_status) { instance_double(Process::Status, success?: true) }
  let(:failure_status) { instance_double(Process::Status, success?: false) }
  let(:logger) { instance_double(Ocak::PipelineLogger, info: nil, warn: nil, error: nil) }
  let(:chdir) { '/project' }
  let(:message) { 'chore: test commit' }

  describe '.commit_changes' do
    context 'when there are no changes (empty porcelain)' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'status', '--porcelain', chdir: chdir)
          .and_return(['', '', success_status])
      end

      it 'returns false' do
        expect(described_class.commit_changes(chdir: chdir, message: message)).to be false
      end

      it 'does not run git add or git commit' do
        described_class.commit_changes(chdir: chdir, message: message)

        expect(Open3).not_to have_received(:capture3).with('git', 'add', '-A', chdir: chdir)
      end
    end

    context 'when changes exist and commit succeeds' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'status', '--porcelain', chdir: chdir)
          .and_return(["M  file.rb\n", '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'add', '-A', chdir: chdir)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'commit', '-m', message, chdir: chdir)
          .and_return(['', '', success_status])
      end

      it 'returns true' do
        expect(described_class.commit_changes(chdir: chdir, message: message)).to be true
      end

      it 'runs git add then git commit in order' do
        expect(Open3).to receive(:capture3)
          .with('git', 'add', '-A', chdir: chdir)
          .ordered
        expect(Open3).to receive(:capture3)
          .with('git', 'commit', '-m', message, chdir: chdir)
          .ordered

        described_class.commit_changes(chdir: chdir, message: message)
      end
    end

    context 'when git add fails' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'status', '--porcelain', chdir: chdir)
          .and_return(["M  file.rb\n", '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'add', '-A', chdir: chdir)
          .and_return(['', 'error: could not add', failure_status])
      end

      it 'returns false' do
        expect(described_class.commit_changes(chdir: chdir, message: message, logger: logger)).to be false
      end

      it 'logs a warning' do
        described_class.commit_changes(chdir: chdir, message: message, logger: logger)

        expect(logger).to have_received(:warn).with(/git add failed/)
      end

      it 'does not run git commit' do
        described_class.commit_changes(chdir: chdir, message: message, logger: logger)

        expect(Open3).not_to have_received(:capture3).with('git', 'commit', '-m', anything, chdir: chdir)
      end
    end

    context 'when git commit fails' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'status', '--porcelain', chdir: chdir)
          .and_return(["M  file.rb\n", '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'add', '-A', chdir: chdir)
          .and_return(['', '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'commit', '-m', message, chdir: chdir)
          .and_return(['', 'nothing to commit', failure_status])
      end

      it 'returns false' do
        expect(described_class.commit_changes(chdir: chdir, message: message, logger: logger)).to be false
      end

      it 'logs a warning' do
        described_class.commit_changes(chdir: chdir, message: message, logger: logger)

        expect(logger).to have_received(:warn).with(/git commit failed/)
      end
    end

    context 'when git status fails' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'status', '--porcelain', chdir: chdir)
          .and_return(['', 'fatal: not a git repo', failure_status])
      end

      it 'returns false' do
        expect(described_class.commit_changes(chdir: chdir, message: message, logger: logger)).to be false
      end

      it 'logs a warning' do
        described_class.commit_changes(chdir: chdir, message: message, logger: logger)

        expect(logger).to have_received(:warn).with(/git status --porcelain failed/)
      end
    end

    context 'without a logger' do
      before do
        allow(Open3).to receive(:capture3)
          .with('git', 'status', '--porcelain', chdir: chdir)
          .and_return(["M  file.rb\n", '', success_status])
        allow(Open3).to receive(:capture3)
          .with('git', 'add', '-A', chdir: chdir)
          .and_return(['', 'error', failure_status])
      end

      it 'does not raise when logger is nil' do
        expect { described_class.commit_changes(chdir: chdir, message: message) }.not_to raise_error
      end

      it 'returns false on failure' do
        expect(described_class.commit_changes(chdir: chdir, message: message)).to be false
      end
    end
  end
end
