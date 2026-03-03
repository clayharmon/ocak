# frozen_string_literal: true

require 'spec_helper'
require 'dry/cli'
require 'ocak/commands/issue/edit'

RSpec.describe Ocak::Commands::Issue::Edit do
  subject(:command) { described_class.new }

  let(:config) do
    instance_double(Ocak::Config, project_dir: '/project')
  end

  before do
    allow(Ocak::Config).to receive(:load).and_return(config)
  end

  context 'when issue file exists' do
    let(:issue_path) { '/project/.ocak/issues/0007.md' }

    before do
      allow(File).to receive(:exist?).with(issue_path).and_return(true)
      allow(command).to receive(:system)
      allow(ENV).to receive(:fetch).with('EDITOR', 'vi').and_return('nano')
    end

    it 'opens the issue file in the editor' do
      command.call(issue: '7')

      expect(command).to have_received(:system).with('nano', issue_path)
    end

    it 'uses vi as default when EDITOR is not set' do
      allow(ENV).to receive(:fetch).with('EDITOR', 'vi').and_return('vi')

      command.call(issue: '7')

      expect(command).to have_received(:system).with('vi', issue_path)
    end
  end

  context 'when issue file does not exist' do
    before do
      allow(File).to receive(:exist?).and_return(false)
    end

    it 'exits with status 1' do
      expect { command.call(issue: '42') }.to raise_error(SystemExit)
    end

    it 'prints an error message to stderr' do
      expect { command.call(issue: '42') }.to output(/Issue #42 not found/).to_stderr.and raise_error(SystemExit)
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
