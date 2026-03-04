# frozen_string_literal: true

module Ocak
  # Resolves an issue's target repo from its body frontmatter.
  # Returns a hash with :name and :path keys, or raises TargetResolutionError.
  module TargetResolver
    class TargetResolutionError < StandardError; end

    # Parses the issue body for a `target_repo:` frontmatter key and resolves
    # it to a configured repo entry via Config#resolve_repo.
    #
    # @param issue [Hash] GitHub issue hash with at least 'body' and 'number' keys
    # @param config [Ocak::Config] project config
    # @return [Hash, nil] { name:, path: } or nil if no target specified
    # @raise [TargetResolutionError] if target name is specified but not configured
    def self.resolve(issue, config:)
      name = extract_target_name(issue['body'] || '')
      return nil unless name

      config.resolve_repo(name)
    rescue Config::ConfigError => e
      raise TargetResolutionError, e.message
    end

    private_class_method def self.extract_target_name(body)
      match = body.match(/^target_repo:\s*(\S+)/)
      match&.captures&.first
    end
  end
end
