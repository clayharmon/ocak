# frozen_string_literal: true

require 'spec_helper'
require 'dry/cli'
require 'ocak/commands/issue/view'

RSpec.describe Ocak::Commands::Issue::View do
  subject(:command) { described_class.new }

  let(:config) do
    instance_double(Ocak::Config, project_dir: '/project')
  end

  let(:fetcher) { instance_double(Ocak::LocalIssueFetcher) }

  before do
    allow(Ocak::Config).to receive(:load).and_return(config)
    allow(Ocak::LocalIssueFetcher).to receive(:new).with(config: config).and_return(fetcher)
  end

  context 'when issue exists' do
    let(:issue_data) do
      {
        'number' => 3,
        'title' => 'Important issue',
        'body' => 'This is the body.',
        'labels' => [{ 'name' => 'bug' }],
        'complexity' => 'full'
      }
    end

    before do
      allow(fetcher).to receive(:view).with(3).and_return(issue_data)
      allow(File).to receive(:exist?).and_return(false)
    end

    it 'prints the issue number and title' do
      expect { command.call(issue: '3') }.to output(/#3\s+Important issue/).to_stdout
    end

    it 'prints the issue labels' do
      expect { command.call(issue: '3') }.to output(/Labels: bug/).to_stdout
    end

    it 'prints the issue body' do
      expect { command.call(issue: '3') }.to output(/This is the body\./).to_stdout
    end

    it 'does not print complexity when it is full' do
      expect { command.call(issue: '3') }.not_to output(/Complexity:/).to_stdout
    end

    context 'when complexity is simple' do
      let(:issue_data) do
        { 'number' => 3, 'title' => 'Simple issue', 'body' => '', 'labels' => [], 'complexity' => 'simple' }
      end

      it 'prints the complexity' do
        expect { command.call(issue: '3') }.to output(/Complexity: simple/).to_stdout
      end
    end
  end

  context 'when issue has pipeline comments' do
    let(:issue_data) do
      { 'number' => 4, 'title' => 'Issue with comments', 'body' => 'body', 'labels' => [], 'complexity' => 'full' }
    end

    let(:issue_path) { '.ocak/issues/0004.md' }
    let(:sentinel) { Ocak::LocalIssueFetcher::COMMENTS_SENTINEL }
    let(:file_content) { "---\n---\nbody\n\n#{sentinel}\n2024-01-01T00:00:00Z — Pipeline started\n" }

    before do
      allow(fetcher).to receive(:view).with(4).and_return(issue_data)
      allow(File).to receive(:exist?).with(issue_path).and_return(true)
      allow(File).to receive(:read).with(issue_path).and_return(file_content)
    end

    it 'shows the pipeline activity section' do
      expect { command.call(issue: '4') }.to output(/Pipeline Activity/).to_stdout
    end

    it 'shows the pipeline comment content' do
      expect { command.call(issue: '4') }.to output(/Pipeline started/).to_stdout
    end
  end

  context 'when issue is not found' do
    before do
      allow(fetcher).to receive(:view).with(99).and_return(nil)
    end

    it 'exits with status 1' do
      expect { command.call(issue: '99') }.to raise_error(SystemExit)
    end

    it 'prints an error message to stderr' do
      expect { command.call(issue: '99') }.to output(/Issue #99 not found/).to_stderr.and raise_error(SystemExit)
    end
  end

  context 'when config is not found' do
    before do
      allow(Ocak::Config).to receive(:load).and_raise(Ocak::Config::ConfigNotFound, 'missing ocak.yml')
    end

    it 'exits with status 1' do
      expect { command.call(issue: '1') }.to raise_error(SystemExit)
    end

    it 'prints an error message to stderr' do
      expect { command.call(issue: '1') }.to output(/missing ocak\.yml/).to_stderr.and raise_error(SystemExit)
    end
  end
end
