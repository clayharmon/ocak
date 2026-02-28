# frozen_string_literal: true

require 'spec_helper'
require 'dry/cli'
require 'tmpdir'
require 'ocak/commands/audit'

RSpec.describe Ocak::Commands::Audit do
  subject(:command) { described_class.new }

  let(:dir) { Dir.mktmpdir }

  before do
    allow(Dir).to receive(:pwd).and_return(dir)
  end

  after { FileUtils.remove_entry(dir) }

  it 'prints usage when skill file exists' do
    skill_dir = File.join(dir, '.claude', 'skills', 'audit')
    FileUtils.mkdir_p(skill_dir)
    File.write(File.join(skill_dir, 'SKILL.md'), '# Audit')

    expect { command.call }.to output(/Run this inside Claude Code/).to_stdout
  end

  it 'includes scope in output when provided' do
    skill_dir = File.join(dir, '.claude', 'skills', 'audit')
    FileUtils.mkdir_p(skill_dir)
    File.write(File.join(skill_dir, 'SKILL.md'), '# Audit')

    expect { command.call(scope: 'security') }.to output(/scope: security/).to_stdout
  end

  it 'exits with error when skill file missing' do
    expect { command.call }.to raise_error(SystemExit)
  end
end
