# frozen_string_literal: true

require_relative 'issue_fetcher'
require_relative 'local_issue_fetcher'

module Ocak
  module IssueBackend
    def self.build(config:, logger: nil)
      case config.issue_backend
      when 'local'
        LocalIssueFetcher.new(config: config, logger: logger)
      when 'github'
        IssueFetcher.new(config: config, logger: logger)
      else
        auto_detect(config: config, logger: logger)
      end
    end

    def self.auto_detect(config:, logger: nil)
      store_dir = File.join(config.project_dir, '.ocak', 'issues')
      has_local = Dir.exist?(store_dir) && Dir.glob(File.join(store_dir, '*.md')).any?

      if has_local
        logger&.info('Auto-detected local issue store in .ocak/issues/')
        LocalIssueFetcher.new(config: config, logger: logger)
      else
        IssueFetcher.new(config: config, logger: logger)
      end
    end
  end
end
