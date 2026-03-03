# frozen_string_literal: true

require 'spec_helper'
require 'dry/cli'
require 'ocak/commands/issue/list'

RSpec.describe Ocak::Commands::Issue::List do
  subject(:command) { described_class.new }

  let(:config) do
    instance_double(Ocak::Config, project_dir: '/project')
  end

  let(:fetcher) { instance_double(Ocak::LocalIssueFetcher) }

  before do
    allow(Ocak::Config).to receive(:load).and_return(config)
    allow(Ocak::LocalIssueFetcher).to receive(:new).with(config: config).and_return(fetcher)
  end

  context 'when there are no issues' do
    before { allow(fetcher).to receive(:all_issues).and_return([]) }

    it 'prints no issues message' do
      expect { command.call }.to output(/No issues found/).to_stdout
    end
  end

  context 'when there are issues without label filter' do
    let(:issues) do
      [
        { 'number' => 2, 'title' => 'Second issue', 'labels' => [] },
        { 'number' => 1, 'title' => 'First issue', 'labels' => [{ 'name' => 'bug' }] }
      ]
    end

    before { allow(fetcher).to receive(:all_issues).and_return(issues) }

    it 'prints all issues sorted by number' do
      output = capture_output { command.call }

      expect(output).to match(/#1\s+First issue/)
      expect(output).to match(/#2\s+Second issue/)
    end

    it 'prints issues in ascending number order' do
      output = capture_output { command.call }
      first_pos = output.index('#1')
      second_pos = output.index('#2')

      expect(first_pos).to be < second_pos
    end

    it 'includes labels in output' do
      expect { command.call }.to output(/\[bug\]/).to_stdout
    end
  end

  context 'when filtering by label' do
    let(:issues) do
      [
        { 'number' => 1, 'title' => 'Bug issue', 'labels' => [{ 'name' => 'bug' }] },
        { 'number' => 2, 'title' => 'Feature issue', 'labels' => [{ 'name' => 'enhancement' }] }
      ]
    end

    before { allow(fetcher).to receive(:all_issues).and_return(issues) }

    it 'only shows issues matching the label' do
      output = capture_output { command.call(label: 'bug') }

      expect(output).to include('Bug issue')
      expect(output).not_to include('Feature issue')
    end

    it 'shows no issues message when filter matches nothing' do
      expect { command.call(label: 'nonexistent') }.to output(/No issues found/).to_stdout
    end
  end

  context 'when config is not found' do
    before do
      allow(Ocak::Config).to receive(:load).and_raise(Ocak::Config::ConfigNotFound, 'missing ocak.yml')
    end

    it 'exits with status 1' do
      expect { command.call }.to raise_error(SystemExit)
    end

    it 'prints an error message to stderr' do
      expect { command.call }.to output(/missing ocak\.yml/).to_stderr.and raise_error(SystemExit)
    end
  end

  def capture_output
    output = StringIO.new
    original = $stdout
    $stdout = output
    yield
    output.string
  ensure
    $stdout = original
  end
end
