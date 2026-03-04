# frozen_string_literal: true

require 'yaml'

module Ocak
  module TargetResolver
    # Resolves the target repo for an issue.
    # Returns { name:, path: } hash or nil (single-repo mode).
    # Raises TargetResolutionError on missing/invalid target in multi-repo mode.
    def self.resolve(issue, config:)
      return nil unless config.multi_repo?

      body = issue['body'].to_s
      repo_name = extract_target_name(body, field: config.target_field)

      unless repo_name
        raise TargetResolutionError,
              "Issue ##{issue['number']} is missing required '#{config.target_field}' field in body. " \
              "Known repos: #{config.repos.keys.join(', ')}"
      end

      config.resolve_repo(repo_name)
    end

    # Extract target name from YAML front-matter.
    # Returns the target name string, or nil if not found.
    def self.extract_target_name(body, field:)
      match = body.match(/\A---\s*\n(.*?)\n---/m)
      return nil unless match

      frontmatter = YAML.safe_load(match[1])
      return nil unless frontmatter.is_a?(Hash)

      frontmatter[field]&.to_s&.strip
    rescue Psych::SyntaxError
      nil
    end

    class TargetResolutionError < StandardError; end
  end
end
