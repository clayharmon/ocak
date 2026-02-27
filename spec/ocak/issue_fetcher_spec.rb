# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Ocak::IssueFetcher do
  let(:config) do
    instance_double(Ocak::Config,
                    project_dir: '/project',
                    label_ready: 'auto-ready',
                    label_in_progress: 'in-progress',
                    label_completed: 'completed',
                    label_failed: 'pipeline-failed',
                    allowed_authors: [],
                    require_comment: nil)
  end

  let(:logger) { instance_double(Ocak::PipelineLogger, info: nil, warn: nil, error: nil) }

  subject(:fetcher) { described_class.new(config: config, logger: logger) }

  let(:success_status) { instance_double(Process::Status, success?: true) }
  let(:failure_status) { instance_double(Process::Status, success?: false) }

  before do
    # Default: current user is 'testuser'
    allow(Open3).to receive(:capture3)
      .with('gh', 'api', 'user', '--jq', '.login')
      .and_return(["testuser\n", '', success_status])
  end

  describe '#fetch_ready' do
    it 'returns issues with the ready label authored by current user' do
      issues_json = JSON.generate([
                                    { 'number' => 1, 'title' => 'Issue 1',
                                      'labels' => [{ 'name' => 'auto-ready' }],
                                      'author' => { 'login' => 'testuser' } },
                                    { 'number' => 2, 'title' => 'Issue 2',
                                      'labels' => [{ 'name' => 'auto-ready' }],
                                      'author' => { 'login' => 'testuser' } }
                                  ])

      allow(Open3).to receive(:capture3)
        .with('gh', 'issue', 'list',
              '--label', 'auto-ready',
              '--state', 'open',
              '--json', 'number,title,body,labels,author',
              '--limit', '50',
              chdir: '/project')
        .and_return([issues_json, '', success_status])

      issues = fetcher.fetch_ready
      expect(issues.size).to eq(2)
      expect(issues.first['number']).to eq(1)
    end

    it 'excludes in-progress issues' do
      issues_json = JSON.generate([
                                    { 'number' => 1, 'title' => 'Issue 1',
                                      'labels' => [{ 'name' => 'auto-ready' }],
                                      'author' => { 'login' => 'testuser' } },
                                    { 'number' => 2, 'title' => 'Issue 2',
                                      'labels' => [
                                        { 'name' => 'auto-ready' },
                                        { 'name' => 'in-progress' }
                                      ],
                                      'author' => { 'login' => 'testuser' } }
                                  ])

      allow(Open3).to receive(:capture3)
        .with('gh', 'issue', 'list', any_args, chdir: '/project')
        .and_return([issues_json, '', success_status])

      issues = fetcher.fetch_ready
      expect(issues.size).to eq(1)
      expect(issues.first['number']).to eq(1)
    end

    it 'returns empty array on gh failure' do
      allow(Open3).to receive(:capture3)
        .with('gh', 'issue', 'list', any_args, chdir: '/project')
        .and_return(['', 'error', failure_status])

      expect(fetcher.fetch_ready).to eq([])
    end

    it 'returns empty array on invalid JSON' do
      allow(Open3).to receive(:capture3)
        .with('gh', 'issue', 'list', any_args, chdir: '/project')
        .and_return(['not json', '', success_status])

      expect(fetcher.fetch_ready).to eq([])
    end

    context 'with safety filtering (default: current user only)' do
      it 'rejects issues from other authors' do
        issues_json = JSON.generate([
                                      { 'number' => 1, 'title' => 'Mine',
                                        'labels' => [{ 'name' => 'auto-ready' }],
                                        'author' => { 'login' => 'testuser' } },
                                      { 'number' => 2, 'title' => 'Theirs',
                                        'labels' => [{ 'name' => 'auto-ready' }],
                                        'author' => { 'login' => 'stranger' } }
                                    ])

        allow(Open3).to receive(:capture3)
          .with('gh', 'issue', 'list', any_args, chdir: '/project')
          .and_return([issues_json, '', success_status])

        issues = fetcher.fetch_ready
        expect(issues.size).to eq(1)
        expect(issues.first['number']).to eq(1)
      end

      it 'logs a warning for rejected issues' do
        issues_json = JSON.generate([
                                      { 'number' => 99, 'title' => 'Unauthorized',
                                        'labels' => [{ 'name' => 'auto-ready' }],
                                        'author' => { 'login' => 'stranger' } }
                                    ])

        allow(Open3).to receive(:capture3)
          .with('gh', 'issue', 'list', any_args, chdir: '/project')
          .and_return([issues_json, '', success_status])

        fetcher.fetch_ready
        expect(logger).to have_received(:warn).with(/stranger.*not in allowed list/)
      end
    end

    context 'with allowed_authors configured' do
      before do
        allow(config).to receive(:allowed_authors).and_return(%w[alice bob])
      end

      it 'accepts issues from allowed authors' do
        issues_json = JSON.generate([
                                      { 'number' => 1, 'title' => 'From Alice',
                                        'labels' => [{ 'name' => 'auto-ready' }],
                                        'author' => { 'login' => 'alice' } },
                                      { 'number' => 2, 'title' => 'From Eve',
                                        'labels' => [{ 'name' => 'auto-ready' }],
                                        'author' => { 'login' => 'eve' } }
                                    ])

        allow(Open3).to receive(:capture3)
          .with('gh', 'issue', 'list', any_args, chdir: '/project')
          .and_return([issues_json, '', success_status])

        issues = fetcher.fetch_ready
        expect(issues.size).to eq(1)
        expect(issues.first['author']['login']).to eq('alice')
      end
    end

    context 'with require_comment configured' do
      before do
        allow(config).to receive(:require_comment).and_return('auto-ready')
      end

      it 'rejects issues without the required comment' do
        issues_json = JSON.generate([
                                      { 'number' => 1, 'title' => 'Mine',
                                        'labels' => [{ 'name' => 'auto-ready' }],
                                        'author' => { 'login' => 'testuser' } }
                                    ])

        allow(Open3).to receive(:capture3)
          .with('gh', 'issue', 'list', any_args, chdir: '/project')
          .and_return([issues_json, '', success_status])

        # No matching comment
        allow(Open3).to receive(:capture3)
          .with('gh', 'issue', 'view', '1', '--json', 'comments', chdir: '/project')
          .and_return([JSON.generate({ 'comments' => [] }), '', success_status])

        issues = fetcher.fetch_ready
        expect(issues).to be_empty
      end

      it 'accepts issues with the required comment from current user' do
        issues_json = JSON.generate([
                                      { 'number' => 1, 'title' => 'Mine',
                                        'labels' => [{ 'name' => 'auto-ready' }],
                                        'author' => { 'login' => 'testuser' } }
                                    ])

        allow(Open3).to receive(:capture3)
          .with('gh', 'issue', 'list', any_args, chdir: '/project')
          .and_return([issues_json, '', success_status])

        comments = { 'comments' => [{ 'author' => { 'login' => 'testuser' }, 'body' => 'auto-ready' }] }
        allow(Open3).to receive(:capture3)
          .with('gh', 'issue', 'view', '1', '--json', 'comments', chdir: '/project')
          .and_return([JSON.generate(comments), '', success_status])

        issues = fetcher.fetch_ready
        expect(issues.size).to eq(1)
      end
    end
  end

  describe '#transition' do
    it 'removes old label and adds new label' do
      expect(Open3).to receive(:capture3)
        .with('gh', 'issue', 'edit', '42', '--remove-label', 'auto-ready', chdir: '/project')
        .and_return(['', '', success_status])

      expect(Open3).to receive(:capture3)
        .with('gh', 'issue', 'edit', '42', '--add-label', 'in-progress', chdir: '/project')
        .and_return(['', '', success_status])

      fetcher.transition(42, from: 'auto-ready', to: 'in-progress')
    end

    it 'only adds label when from is nil' do
      expect(Open3).to receive(:capture3)
        .with('gh', 'issue', 'edit', '42', '--add-label', 'completed', chdir: '/project')
        .and_return(['', '', success_status])

      fetcher.transition(42, from: nil, to: 'completed')
    end
  end

  describe '#view' do
    it 'returns parsed issue data' do
      issue_json = JSON.generate({ 'number' => 42, 'title' => 'Test', 'body' => 'Description' })

      allow(Open3).to receive(:capture3)
        .with('gh', 'issue', 'view', '42', '--json', 'number,title,body,labels', chdir: '/project')
        .and_return([issue_json, '', success_status])

      result = fetcher.view(42)
      expect(result['number']).to eq(42)
      expect(result['title']).to eq('Test')
    end

    it 'returns nil on failure' do
      allow(Open3).to receive(:capture3)
        .with('gh', 'issue', 'view', any_args, chdir: '/project')
        .and_return(['', 'not found', failure_status])

      expect(fetcher.view(999)).to be_nil
    end
  end
end
