# frozen_string_literal: true

require 'spec_helper'
require 'ocak/cli'

RSpec.describe Ocak::CLI do
  describe 'command registration' do
    let(:registry) { Ocak::CLI::Commands }

    expected_commands = {
      'init' => Ocak::Commands::Init,
      'run' => Ocak::Commands::Run,
      'design' => Ocak::Commands::Design,
      'audit' => Ocak::Commands::Audit,
      'debt' => Ocak::Commands::Debt,
      'status' => Ocak::Commands::Status,
      'clean' => Ocak::Commands::Clean,
      'resume' => Ocak::Commands::Resume,
      'hiz' => Ocak::Commands::Hiz
    }.freeze

    it 'registers all 9 commands' do
      expected_commands.each_key do |name|
        result = registry.get([name])
        expect(result).to be_found, "expected '#{name}' to be registered"
      end
    end

    expected_commands.each do |name, klass|
      it "maps '#{name}' to #{klass}" do
        result = registry.get([name])
        expect(result.command).to eq(klass)
      end

      it "has a non-empty description for '#{name}'" do
        expect(klass.description).to be_a(String).and(satisfy('be non-empty') { |s| !s.strip.empty? })
      end
    end
  end
end
