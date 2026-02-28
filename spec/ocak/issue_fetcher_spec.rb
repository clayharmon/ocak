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

  describe '#fetch_reready_prs' do
    before do
      allow(config).to receive(:label_reready).and_return('auto-reready')
    end

    it 'returns parsed PR list' do
      prs_json = JSON.generate([
                                 { 'number' => 10, 'title' => 'Fix #1',
                                   'body' => 'Closes #1', 'headRefName' => 'auto/issue-1-abc',
                                   'labels' => [{ 'name' => 'auto-reready' }] }
                               ])

      allow(Open3).to receive(:capture3)
        .with('gh', 'pr', 'list',
              '--label', 'auto-reready',
              '--state', 'open',
              '--json', 'number,title,body,headRefName,labels',
              '--limit', '20',
              chdir: '/project')
        .and_return([prs_json, '', success_status])

      prs = fetcher.fetch_reready_prs
      expect(prs.size).to eq(1)
      expect(prs.first['number']).to eq(10)
    end

    it 'returns empty array on failure' do
      allow(Open3).to receive(:capture3)
        .with('gh', 'pr', 'list', any_args, chdir: '/project')
        .and_return(['', 'error', failure_status])

      expect(fetcher.fetch_reready_prs).to eq([])
    end

    it 'returns empty array on invalid JSON' do
      allow(Open3).to receive(:capture3)
        .with('gh', 'pr', 'list', any_args, chdir: '/project')
        .and_return(['not json', '', success_status])

      expect(fetcher.fetch_reready_prs).to eq([])
    end
  end

  describe '#fetch_pr_comments' do
    it 'returns comments and reviews' do
      data = {
        'comments' => [{ 'author' => { 'login' => 'user' }, 'body' => 'fix this' }],
        'reviews' => [{ 'author' => { 'login' => 'reviewer' }, 'body' => 'needs work', 'state' => 'CHANGES_REQUESTED' }]
      }

      allow(Open3).to receive(:capture3)
        .with('gh', 'pr', 'view', '10', '--json', 'comments,reviews', chdir: '/project')
        .and_return([JSON.generate(data), '', success_status])

      result = fetcher.fetch_pr_comments(10)
      expect(result[:comments].size).to eq(1)
      expect(result[:reviews].size).to eq(1)
    end

    it 'returns empty arrays on failure' do
      allow(Open3).to receive(:capture3)
        .with('gh', 'pr', 'view', any_args, chdir: '/project')
        .and_return(['', 'error', failure_status])

      result = fetcher.fetch_pr_comments(10)
      expect(result[:comments]).to eq([])
      expect(result[:reviews]).to eq([])
    end
  end

  describe '#extract_issue_number_from_pr' do
    it 'extracts from Closes #N' do
      pr = { 'body' => 'This PR Closes #42' }
      expect(fetcher.extract_issue_number_from_pr(pr)).to eq(42)
    end

    it 'extracts from Fixes #N' do
      pr = { 'body' => 'Fixes #7 with some changes' }
      expect(fetcher.extract_issue_number_from_pr(pr)).to eq(7)
    end

    it 'extracts from Resolves #N (case insensitive)' do
      pr = { 'body' => 'resolves #100' }
      expect(fetcher.extract_issue_number_from_pr(pr)).to eq(100)
    end

    it 'returns nil when no match' do
      pr = { 'body' => 'Just some changes' }
      expect(fetcher.extract_issue_number_from_pr(pr)).to be_nil
    end

    it 'returns nil when body is nil' do
      pr = { 'body' => nil }
      expect(fetcher.extract_issue_number_from_pr(pr)).to be_nil
    end
  end

  describe '#pr_transition' do
    it 'removes and adds labels' do
      expect(Open3).to receive(:capture3)
        .with('gh', 'pr', 'edit', '10', '--remove-label', 'auto-reready', chdir: '/project')
        .and_return(['', '', success_status])

      expect(Open3).to receive(:capture3)
        .with('gh', 'pr', 'edit', '10', '--add-label', 'auto-pending-human', chdir: '/project')
        .and_return(['', '', success_status])

      result = fetcher.pr_transition(10, remove_label: 'auto-reready', add_label: 'auto-pending-human')
      expect(result).to be true
    end

    it 'only removes label when add_label is nil' do
      expect(Open3).to receive(:capture3)
        .with('gh', 'pr', 'edit', '10', '--remove-label', 'auto-reready', chdir: '/project')
        .and_return(['', '', success_status])

      result = fetcher.pr_transition(10, remove_label: 'auto-reready')
      expect(result).to be true
    end

    it 'returns false when remove fails' do
      allow(Open3).to receive(:capture3)
        .with('gh', 'pr', 'edit', '10', '--remove-label', 'auto-reready', chdir: '/project')
        .and_return(['', 'error', failure_status])

      result = fetcher.pr_transition(10, remove_label: 'auto-reready')
      expect(result).to be false
    end
  end

  describe '#pr_comment' do
    it 'comments on a PR' do
      expect(Open3).to receive(:capture3)
        .with('gh', 'pr', 'comment', '10', '--body', 'Feedback addressed.', chdir: '/project')
        .and_return(['', '', success_status])

      expect(fetcher.pr_comment(10, 'Feedback addressed.')).to be true
    end

    it 'returns false on failure' do
      allow(Open3).to receive(:capture3)
        .with('gh', 'pr', 'comment', any_args, chdir: '/project')
        .and_return(['', 'error', failure_status])

      expect(fetcher.pr_comment(10, 'test')).to be false
    end
  end

  describe '#ensure_labels' do
    it 'calls gh label create --force with color for each label' do
      allow(Open3).to receive(:capture3).and_return(['', '', success_status])

      fetcher.ensure_labels(%w[auto-ready auto-doing])

      expect(Open3).to have_received(:capture3)
        .with('gh', 'label', 'create', 'auto-ready', '--force', '--color', '0E8A16', chdir: '/project')
      expect(Open3).to have_received(:capture3)
        .with('gh', 'label', 'create', 'auto-doing', '--force', '--color', '1D76DB', chdir: '/project')
    end

    it 'handles failures gracefully' do
      allow(Open3).to receive(:capture3)
        .with('gh', 'label', 'create', anything, '--force', '--color', anything, chdir: '/project')
        .and_raise(Errno::ENOENT, 'gh not found')

      expect { fetcher.ensure_labels(%w[auto-ready]) }.not_to raise_error
    end
  end

  describe '#ensure_label' do
    it 'calls gh label create --force with the correct color for a known label' do
      allow(Open3).to receive(:capture3).and_return(['', '', success_status])

      fetcher.ensure_label('auto-doing')

      expect(Open3).to have_received(:capture3)
        .with('gh', 'label', 'create', 'auto-doing', '--force', '--color', '1D76DB', chdir: '/project')
    end

    it 'uses fallback color for unknown labels' do
      allow(Open3).to receive(:capture3).and_return(['', '', success_status])

      fetcher.ensure_label('some-unknown-label')

      expect(Open3).to have_received(:capture3)
        .with('gh', 'label', 'create', 'some-unknown-label', '--force', '--color', 'ededed', chdir: '/project')
    end
  end

  describe '#current_user (private)' do
    it 'returns the login on success' do
      allow(Open3).to receive(:capture3)
        .with('gh', 'api', 'user', '--jq', '.login')
        .and_return(["testuser\n", '', success_status])

      expect(fetcher.send(:current_user)).to eq('testuser')
    end

    it 'logs a warning when gh api user fails' do
      allow(Open3).to receive(:capture3)
        .with('gh', 'api', 'user', '--jq', '.login')
        .and_return(['', 'error', failure_status])

      fetcher.send(:current_user)

      expect(logger).to have_received(:warn).with("Could not determine current user via 'gh api user'")
    end

    it 'returns nil when gh api user fails' do
      allow(Open3).to receive(:capture3)
        .with('gh', 'api', 'user', '--jq', '.login')
        .and_return(['', 'error', failure_status])

      expect(fetcher.send(:current_user)).to be_nil
    end

    it 'does not memoize nil — retries on next call' do
      allow(Open3).to receive(:capture3)
        .with('gh', 'api', 'user', '--jq', '.login')
        .and_return(['', 'error', failure_status],
                    ["testuser\n", '', success_status])

      expect(fetcher.send(:current_user)).to be_nil
      expect(fetcher.send(:current_user)).to eq('testuser')
    end

    it 'memoizes successful result' do
      allow(Open3).to receive(:capture3)
        .with('gh', 'api', 'user', '--jq', '.login')
        .and_return(["testuser\n", '', success_status])

      fetcher.send(:current_user)
      fetcher.send(:current_user)

      expect(Open3).to have_received(:capture3)
        .with('gh', 'api', 'user', '--jq', '.login')
        .once
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
