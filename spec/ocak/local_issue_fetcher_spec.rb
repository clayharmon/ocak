# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Ocak::LocalIssueFetcher do
  let(:tmpdir) { Dir.mktmpdir }
  let(:store_dir) { File.join(tmpdir, '.ocak', 'issues') }
  let(:config) do
    instance_double(Ocak::Config,
                    project_dir: tmpdir,
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
  subject(:fetcher) { described_class.new(config: config, logger: logger) }

  after { FileUtils.rm_rf(tmpdir) }

  def write_issue(number, title:, labels: [], body: '', complexity: 'full')
    FileUtils.mkdir_p(store_dir)
    fm = {
      'number' => number,
      'title' => title,
      'labels' => labels,
      'complexity' => complexity,
      'created_at' => '2026-01-01T00:00:00Z'
    }
    path = File.join(store_dir, format('%04d.md', number))
    yaml = YAML.dump(fm).delete_prefix("---\n")
    File.write(path, "---\n#{yaml}---\n\n#{body}\n")
    path
  end

  describe '#fetch_ready' do
    it 'returns issues with the ready label' do
      write_issue(1, title: 'Ready issue', labels: ['auto-ready'])
      write_issue(2, title: 'Not ready', labels: ['other'])

      issues = fetcher.fetch_ready
      expect(issues.size).to eq(1)
      expect(issues.first['number']).to eq(1)
      expect(issues.first['title']).to eq('Ready issue')
    end

    it 'excludes in-progress issues' do
      write_issue(1, title: 'In progress', labels: %w[auto-ready auto-doing])
      write_issue(2, title: 'Ready only', labels: ['auto-ready'])

      issues = fetcher.fetch_ready
      expect(issues.size).to eq(1)
      expect(issues.first['number']).to eq(2)
    end

    it 'returns empty array when store dir does not exist' do
      expect(fetcher.fetch_ready).to eq([])
    end

    it 'returns issues with correct hash shape' do
      write_issue(1, title: 'Test', labels: ['auto-ready'], body: 'The body')

      issue = fetcher.fetch_ready.first
      expect(issue['number']).to eq(1)
      expect(issue['title']).to eq('Test')
      expect(issue['body']).to eq('The body')
      expect(issue['labels']).to eq([{ 'name' => 'auto-ready' }])
      expect(issue['author']).to eq({ 'login' => 'local' })
      expect(issue['complexity']).to eq('full')
    end
  end

  describe '#view' do
    it 'returns issue hash for existing issue' do
      write_issue(1, title: 'My Issue', body: 'Details here', labels: ['auto-ready'])

      result = fetcher.view(1)
      expect(result['number']).to eq(1)
      expect(result['title']).to eq('My Issue')
      expect(result['body']).to eq('Details here')
    end

    it 'returns nil for non-existent issue' do
      FileUtils.mkdir_p(store_dir)
      expect(fetcher.view(999)).to be_nil
    end

    it 'accepts fields: keyword without error' do
      write_issue(1, title: 'Test', labels: [])
      expect(fetcher.view(1, fields: 'title')).to be_a(Hash)
    end

    it 'strips pipeline comments from body' do
      path = write_issue(1, title: 'Test', body: 'Real body')
      File.open(path, 'a') do |f|
        f.write("\n<!-- pipeline-comments -->\n2026-01-01T00:00:00Z — Pipeline started\n")
      end

      result = fetcher.view(1)
      expect(result['body']).to eq('Real body')
    end
  end

  describe '#add_label' do
    it 'adds a label to the issue frontmatter' do
      write_issue(1, title: 'Test', labels: ['existing'])

      fetcher.add_label(1, 'new-label')

      result = fetcher.view(1)
      expect(result['labels'].map { |l| l['name'] }).to contain_exactly('existing', 'new-label')
    end

    it 'does not duplicate existing labels' do
      write_issue(1, title: 'Test', labels: ['auto-ready'])

      fetcher.add_label(1, 'auto-ready')

      result = fetcher.view(1)
      expect(result['labels'].map { |l| l['name'] }).to eq(['auto-ready'])
    end
  end

  describe '#remove_label' do
    it 'removes a label from the issue frontmatter' do
      write_issue(1, title: 'Test', labels: %w[auto-ready auto-doing])

      fetcher.remove_label(1, 'auto-ready')

      result = fetcher.view(1)
      expect(result['labels'].map { |l| l['name'] }).to eq(['auto-doing'])
    end

    it 'is a no-op when label not present' do
      write_issue(1, title: 'Test', labels: ['auto-ready'])

      fetcher.remove_label(1, 'nonexistent')

      result = fetcher.view(1)
      expect(result['labels'].map { |l| l['name'] }).to eq(['auto-ready'])
    end
  end

  describe '#transition' do
    it 'removes from label and adds to label' do
      write_issue(1, title: 'Test', labels: ['auto-ready'])

      fetcher.transition(1, from: 'auto-ready', to: 'auto-doing')

      result = fetcher.view(1)
      labels = result['labels'].map { |l| l['name'] }
      expect(labels).to contain_exactly('auto-doing')
    end

    it 'works with nil from label' do
      write_issue(1, title: 'Test', labels: [])

      fetcher.transition(1, from: nil, to: 'auto-ready')

      result = fetcher.view(1)
      expect(result['labels'].map { |l| l['name'] }).to eq(['auto-ready'])
    end
  end

  describe '#comment' do
    it 'appends comment with sentinel on first call' do
      path = write_issue(1, title: 'Test', body: 'Body text')

      fetcher.comment(1, 'Pipeline started')

      content = File.read(path)
      expect(content).to include('<!-- pipeline-comments -->')
      expect(content).to match(/\d{4}-\d{2}-\d{2}T.*— Pipeline started/)
    end

    it 'appends subsequent comments without duplicating sentinel' do
      path = write_issue(1, title: 'Test', body: 'Body')

      fetcher.comment(1, 'First')
      fetcher.comment(1, 'Second')

      content = File.read(path)
      expect(content.scan('<!-- pipeline-comments -->').size).to eq(1)
      expect(content).to include('First')
      expect(content).to include('Second')
    end

    it 'does not crash for non-existent issue' do
      FileUtils.mkdir_p(store_dir)
      expect { fetcher.comment(999, 'test') }.not_to raise_error
    end
  end

  describe '#create' do
    it 'creates issue file with auto-incremented number' do
      number = fetcher.create(title: 'First issue', body: 'Body', labels: ['auto-ready'])

      expect(number).to eq(1)
      expect(File.exist?(File.join(store_dir, '0001.md'))).to be true

      result = fetcher.view(1)
      expect(result['title']).to eq('First issue')
      expect(result['body']).to eq('Body')
      expect(result['labels']).to eq([{ 'name' => 'auto-ready' }])
    end

    it 'increments past existing issues' do
      fetcher.create(title: 'First', labels: [])
      fetcher.create(title: 'Second', labels: [])

      expect(File.exist?(File.join(store_dir, '0001.md'))).to be true
      expect(File.exist?(File.join(store_dir, '0002.md'))).to be true
      expect(fetcher.view(2)['title']).to eq('Second')
    end

    it 'creates .ocak/issues/ directory if missing' do
      expect(Dir.exist?(store_dir)).to be false
      fetcher.create(title: 'Test', labels: [])
      expect(Dir.exist?(store_dir)).to be true
    end

    it 'stores complexity field' do
      fetcher.create(title: 'Simple', labels: [], complexity: 'simple')

      result = fetcher.view(1)
      expect(result['complexity']).to eq('simple')
    end
  end

  describe '#all_issues' do
    it 'returns all issues from the store' do
      write_issue(1, title: 'First', labels: ['auto-ready'])
      write_issue(2, title: 'Second', labels: ['completed'])

      issues = fetcher.all_issues
      expect(issues.size).to eq(2)
    end

    it 'returns empty array when no issues exist' do
      expect(fetcher.all_issues).to eq([])
    end
  end

  describe '#ensure_label' do
    it 'is a no-op' do
      expect(fetcher.ensure_label('anything')).to be_nil
    end
  end

  describe '#ensure_labels' do
    it 'is a no-op' do
      expect(fetcher.ensure_labels(%w[a b c])).to be_nil
    end
  end
end
