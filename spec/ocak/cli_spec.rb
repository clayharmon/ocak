# frozen_string_literal: true

require 'spec_helper'
require 'ocak/cli'

RSpec.describe Ocak::CLI do
  describe 'command registration' do
    let(:registry) { Ocak::CLI::Commands }

    %w[init run design audit debt status clean resume hiz].each do |cmd_name|
      it "registers the #{cmd_name} command" do
        command_class = Ocak::Commands.const_get(cmd_name.capitalize)
        expect(command_class).to be < Dry::CLI::Command
      end
    end
  end
end
