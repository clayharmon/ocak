# frozen_string_literal: true

require 'spec_helper'
require 'dry/cli'
require 'ocak/commands/issue/close'

RSpec.describe Ocak::Commands::Issue::Close do
  subject(:command) { described_class.new }

  let(:config) do
    instance_double(Ocak::Config,
                    project_dir: '/project',
                    label_ready: 'auto-ready',
                    label_in_progress: 'auto-doing',
                    label_completed: 'completed')
  end

  let(:fetcher) do
    instance_double(Ocak::LocalIssueFetcher,
                    view: nil,
                    remove_label: nil,
                    add_label: nil)
  end

  before do
    allow(Ocak::Config).to receive(:load).and_return(config)
    allow(Ocak::LocalIssueFetcher).to receive(:new).with(config: config).and_return(fetcher)
  end

  context 'when issue exists' do
    let(:issue_data) { { 'number' => 5, 'title' => 'Fix the bug' } }

    before do
      allow(fetcher).to receive(:view).with(5).and_return(issue_data)
    end

    it 'removes ready and in-progress labels and adds completed label' do
      command.call(issue: '5')

      expect(fetcher).to have_received(:remove_label).with(5, 'auto-ready')
      expect(fetcher).to have_received(:remove_label).with(5, 'auto-doing')
      expect(fetcher).to have_received(:add_label).with(5, 'completed')
    end

    it 'prints the closed issue title' do
      expect { command.call(issue: '5') }.to output(/Closed issue #5: Fix the bug/).to_stdout
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
