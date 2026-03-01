# frozen_string_literal: true

require 'dry/cli'
require_relative 'commands/init'
require_relative 'commands/run'
require_relative 'commands/design'
require_relative 'commands/audit'
require_relative 'commands/debt'
require_relative 'commands/status'
require_relative 'commands/clean'
require_relative 'commands/resume'
require_relative 'commands/hiz'
require_relative 'commands/issue/create'
require_relative 'commands/issue/list'
require_relative 'commands/issue/view'
require_relative 'commands/issue/edit'
require_relative 'commands/issue/close'

module Ocak
  module CLI
    module Commands
      extend Dry::CLI::Registry

      register 'init',   Ocak::Commands::Init
      register 'run',    Ocak::Commands::Run
      register 'design', Ocak::Commands::Design
      register 'audit',  Ocak::Commands::Audit
      register 'debt',   Ocak::Commands::Debt
      register 'status', Ocak::Commands::Status
      register 'clean',  Ocak::Commands::Clean
      register 'resume', Ocak::Commands::Resume
      register 'hiz',    Ocak::Commands::Hiz

      register 'issue' do |prefix|
        prefix.register 'create', Ocak::Commands::Issue::Create
        prefix.register 'list',   Ocak::Commands::Issue::List
        prefix.register 'view',   Ocak::Commands::Issue::View
        prefix.register 'edit',   Ocak::Commands::Issue::Edit
        prefix.register 'close',  Ocak::Commands::Issue::Close
      end
    end
  end
end
