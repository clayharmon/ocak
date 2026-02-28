# frozen_string_literal: true

require 'spec_helper'
require 'dry/cli'
require 'tmpdir'
require 'ocak/commands/design'

RSpec.describe Ocak::Commands::Design do
  subject(:command) { described_class.new }

  let(:dir) { Dir.mktmpdir }

  before do
    allow(Dir).to receive(:pwd).and_return(dir)
  end

  after { FileUtils.remove_entry(dir) }

  it 'execs claude interactively when no description given' do
    skill_dir = File.join(dir, '.claude', 'skills', 'design')
    FileUtils.mkdir_p(skill_dir)
    File.write(File.join(skill_dir, 'SKILL.md'), '# Design')

    skill_path = File.join(skill_dir, 'SKILL.md')
    allow(command).to receive(:exec)

    command.call

    expect(command).to have_received(:exec).with('claude', '--skill', skill_path)
  end

  it 'execs claude with description when provided' do
    skill_dir = File.join(dir, '.claude', 'skills', 'design')
    FileUtils.mkdir_p(skill_dir)
    File.write(File.join(skill_dir, 'SKILL.md'), '# Design')

    skill_path = File.join(skill_dir, 'SKILL.md')
    allow(command).to receive(:exec)

    command.call(description: 'add auth')

    expect(command).to have_received(:exec).with('claude', '--skill', skill_path, '--', 'add auth')
  end

  it 'exits with error when skill file missing' do
    expect { command.call }.to raise_error(SystemExit)
  end
end
