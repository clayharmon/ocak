# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Ocak::IssueFetcher do
  let(:config) do
    instance_double(Ocak::Config,
                    project_dir: '/project',
                    label_ready: 'auto-ready',
                    label_in_progress: 'in-progress',
                    label_completed: 'completed',
                    label_failed: 'pipeline-failed')
  end

  subject(:fetcher) { described_class.new(config: config) }

  describe '#fetch_ready' do
    it 'returns issues with the ready label' do
      issues_json = JSON.generate([
                                    { 'number' => 1, 'title' => 'Issue 1', 'labels' => [{ 'name' => 'auto-ready' }] },
                                    { 'number' => 2, 'title' => 'Issue 2', 'labels' => [{ 'name' => 'auto-ready' }] }
                                  ])

      allow(Open3).to receive(:capture3)
        .with('gh', 'issue', 'list',
              '--label', 'auto-ready',
              '--state', 'open',
              '--json', 'number,title,body,labels',
              '--limit', '50',
              chdir: '/project')
        .and_return([issues_json, '', instance_double(Process::Status, success?: true)])

      issues = fetcher.fetch_ready
      expect(issues.size).to eq(2)
      expect(issues.first['number']).to eq(1)
    end

    it 'excludes in-progress issues' do
      issues_json = JSON.generate([
                                    { 'number' => 1, 'title' => 'Issue 1', 'labels' => [{ 'name' => 'auto-ready' }] },
                                    { 'number' => 2, 'title' => 'Issue 2', 'labels' => [
                                      { 'name' => 'auto-ready' },
                                      { 'name' => 'in-progress' }
                                    ] }
                                  ])

      allow(Open3).to receive(:capture3)
        .with('gh', 'issue', 'list', any_args, chdir: '/project')
        .and_return([issues_json, '', instance_double(Process::Status, success?: true)])

      issues = fetcher.fetch_ready
      expect(issues.size).to eq(1)
      expect(issues.first['number']).to eq(1)
    end

    it 'returns empty array on gh failure' do
      allow(Open3).to receive(:capture3)
        .and_return(['', 'error', instance_double(Process::Status, success?: false)])

      expect(fetcher.fetch_ready).to eq([])
    end

    it 'returns empty array on invalid JSON' do
      allow(Open3).to receive(:capture3)
        .and_return(['not json', '', instance_double(Process::Status, success?: true)])

      expect(fetcher.fetch_ready).to eq([])
    end
  end

  describe '#transition' do
    it 'removes old label and adds new label' do
      expect(Open3).to receive(:capture3)
        .with('gh', 'issue', 'edit', '42', '--remove-label', 'auto-ready', chdir: '/project')
        .and_return(['', '', instance_double(Process::Status, success?: true)])

      expect(Open3).to receive(:capture3)
        .with('gh', 'issue', 'edit', '42', '--add-label', 'in-progress', chdir: '/project')
        .and_return(['', '', instance_double(Process::Status, success?: true)])

      fetcher.transition(42, from: 'auto-ready', to: 'in-progress')
    end

    it 'only adds label when from is nil' do
      expect(Open3).to receive(:capture3)
        .with('gh', 'issue', 'edit', '42', '--add-label', 'completed', chdir: '/project')
        .and_return(['', '', instance_double(Process::Status, success?: true)])

      fetcher.transition(42, from: nil, to: 'completed')
    end
  end

  describe '#view' do
    it 'returns parsed issue data' do
      issue_json = JSON.generate({ 'number' => 42, 'title' => 'Test', 'body' => 'Description' })

      allow(Open3).to receive(:capture3)
        .with('gh', 'issue', 'view', '42', '--json', 'number,title,body,labels', chdir: '/project')
        .and_return([issue_json, '', instance_double(Process::Status, success?: true)])

      result = fetcher.view(42)
      expect(result['number']).to eq(42)
      expect(result['title']).to eq('Test')
    end

    it 'returns nil on failure' do
      allow(Open3).to receive(:capture3)
        .and_return(['', 'not found', instance_double(Process::Status, success?: false)])

      expect(fetcher.view(999)).to be_nil
    end
  end
end
