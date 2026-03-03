# frozen_string_literal: true

require 'spec_helper'
require 'dry/cli'
require 'ocak/commands/issue/create'

RSpec.describe Ocak::Commands::Issue::Create do
  subject(:command) { described_class.new }

  let(:config) do
    instance_double(Ocak::Config, project_dir: '/project')
  end

  let(:fetcher) do
    instance_double(Ocak::LocalIssueFetcher, create: 1)
  end

  before do
    allow(Ocak::Config).to receive(:load).and_return(config)
    allow(Ocak::LocalIssueFetcher).to receive(:new).with(config: config).and_return(fetcher)
  end

  context 'when body is provided via option' do
    it 'creates the issue with provided body' do
      command.call(title: 'My issue', body: 'Some body text', label: [], complexity: 'full')

      expect(fetcher).to have_received(:create).with(
        title: 'My issue',
        body: 'Some body text',
        labels: [],
        complexity: 'full'
      )
    end

    it 'prints the created issue number and path' do
      expect do
        command.call(title: 'My issue', body: 'Some body text', label: [], complexity: 'full')
      end.to output(/Created issue #1/).to_stdout
    end

    it 'includes the file path in output' do
      expect do
        command.call(title: 'My issue', body: 'Some body text', label: [], complexity: 'full')
      end.to output(%r{\.ocak/issues/0001\.md}).to_stdout
    end
  end

  context 'when body is empty and editor is used' do
    before do
      allow(ENV).to receive(:fetch).with('EDITOR', 'vi').and_return('myeditor')
      allow(command).to receive(:system)
    end

    it 'opens an editor when body is empty' do
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(a_string_matching(/ocak-issue/)).and_return("My issue\n\nEditor body text")

      command.call(title: 'My issue', body: '', label: [], complexity: 'full')

      expect(command).to have_received(:system).with('myeditor', anything)
    end

    it 'passes editor content as body' do
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(a_string_matching(/ocak-issue/)).and_return("My issue\n\nEditor body text")

      command.call(title: 'My issue', body: '', label: [], complexity: 'full')

      expect(fetcher).to have_received(:create).with(
        title: 'My issue',
        body: 'Editor body text',
        labels: [],
        complexity: 'full'
      )
    end

    it 'strips the title line from editor content when present' do
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(a_string_matching(/ocak-issue/)).and_return("My issue\n\nJust the body")

      command.call(title: 'My issue', body: '', label: [], complexity: 'full')

      expect(fetcher).to have_received(:create).with(
        hash_including(body: 'Just the body')
      )
    end
  end

  context 'with labels' do
    it 'passes labels to fetcher' do
      command.call(title: 'My issue', body: 'body', label: %w[bug urgent], complexity: 'full')

      expect(fetcher).to have_received(:create).with(
        hash_including(labels: %w[bug urgent])
      )
    end
  end

  context 'with simple complexity' do
    it 'passes complexity to fetcher' do
      command.call(title: 'My issue', body: 'body', label: [], complexity: 'simple')

      expect(fetcher).to have_received(:create).with(
        hash_including(complexity: 'simple')
      )
    end
  end

  context 'when config is not found' do
    before do
      allow(Ocak::Config).to receive(:load).and_raise(Ocak::Config::ConfigNotFound, 'missing ocak.yml')
    end

    it 'exits with status 1' do
      expect { command.call(title: 'My issue', body: 'body', label: [], complexity: 'full') }.to raise_error(SystemExit)
    end

    it 'prints an error message to stderr' do
      expect do
        command.call(title: 'My issue', body: 'body', label: [], complexity: 'full')
      end.to output(/missing ocak\.yml/).to_stderr.and raise_error(SystemExit)
    end
  end
end
