# frozen_string_literal: true

require 'ocak'
require 'ocak/config'
require 'ocak/stack_detector'
require 'ocak/worktree_manager'
require 'ocak/issue_fetcher'
require 'ocak/merge_manager'
require 'ocak/process_runner'
require 'ocak/stream_parser'
require 'ocak/claude_runner'
require 'ocak/pipeline_executor'
require 'ocak/reready_processor'
require 'ocak/logger'

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
