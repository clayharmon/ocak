# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Ocak::IssueBackend do
  let(:tmpdir) { Dir.mktmpdir }
  let(:store_dir) { File.join(tmpdir, '.ocak', 'issues') }

  let(:config) do
    instance_double(Ocak::Config,
                    project_dir: tmpdir,
                    issue_backend: issue_backend_value,
                    label_ready: 'auto-ready',
                    label_in_progress: 'auto-doing',
                    label_completed: 'completed',
                    label_failed: 'pipeline-failed',
                    label_reready: 'auto-reready',
                    label_awaiting_review: 'auto-pending-human',
                    allowed_authors: [],
                    require_comment: nil)
  end

  let(:logger) { instance_double(Ocak::PipelineLogger, info: nil, warn: nil, error: nil) }

  after { FileUtils.rm_rf(tmpdir) }

  describe '.build' do
    context 'when issue_backend is "local"' do
      let(:issue_backend_value) { 'local' }

      it 'returns a LocalIssueFetcher instance' do
        result = described_class.build(config: config, logger: logger)
        expect(result).to be_a(Ocak::LocalIssueFetcher)
      end
    end

    context 'when issue_backend is "github"' do
      let(:issue_backend_value) { 'github' }

      it 'returns an IssueFetcher instance' do
        result = described_class.build(config: config, logger: logger)
        expect(result).to be_a(Ocak::IssueFetcher)
      end
    end

    context 'when issue_backend is "auto"' do
      let(:issue_backend_value) { 'auto' }

      it 'calls auto_detect' do
        expect(described_class).to receive(:auto_detect).with(config: config, logger: logger)
        described_class.build(config: config, logger: logger)
      end
    end

    context 'when issue_backend is nil' do
      let(:issue_backend_value) { nil }

      it 'calls auto_detect' do
        expect(described_class).to receive(:auto_detect).with(config: config, logger: logger)
        described_class.build(config: config, logger: logger)
      end
    end
  end

  describe '.auto_detect' do
    let(:issue_backend_value) { 'auto' }

    context 'when local issue store exists with issues' do
      before do
        FileUtils.mkdir_p(store_dir)
        File.write(File.join(store_dir, '0001.md'), "---\ntitle: Test\n---\n")
      end

      it 'returns a LocalIssueFetcher instance' do
        result = described_class.auto_detect(config: config, logger: logger)
        expect(result).to be_a(Ocak::LocalIssueFetcher)
      end

      it 'logs auto-detection message' do
        described_class.auto_detect(config: config, logger: logger)
        expect(logger).to have_received(:info).with('Auto-detected local issue store in .ocak/issues/')
      end
    end

    context 'when local issue store directory exists but is empty' do
      before do
        FileUtils.mkdir_p(store_dir)
      end

      it 'returns an IssueFetcher instance' do
        result = described_class.auto_detect(config: config, logger: logger)
        expect(result).to be_a(Ocak::IssueFetcher)
      end
    end

    context 'when local issue store does not exist' do
      it 'returns an IssueFetcher instance' do
        result = described_class.auto_detect(config: config, logger: logger)
        expect(result).to be_a(Ocak::IssueFetcher)
      end
    end

    context 'when nil logger is provided' do
      before do
        FileUtils.mkdir_p(store_dir)
        File.write(File.join(store_dir, '0001.md'), "---\ntitle: Test\n---\n")
      end

      it 'does not crash' do
        expect { described_class.auto_detect(config: config, logger: nil) }.not_to raise_error
      end
    end
  end
end
