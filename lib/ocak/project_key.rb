# frozen_string_literal: true

require 'open3'

module Ocak
  module ProjectKey
    class NoRemoteError < StandardError; end

    # Resolve owner/repo from git remote origin.
    # Returns a string like "owner/repo".
    # Raises NoRemoteError if no remote or URL is unparseable.
    def self.resolve(dir = Dir.pwd)
      url = fetch_remote_url(dir)
      parse_url(url)
    end

    def self.fetch_remote_url(dir)
      stdout, _stderr, status = Open3.capture3('git', 'remote', 'get-url', 'origin', chdir: dir)
      raise NoRemoteError, "No git remote 'origin' found in #{dir}" unless status.success?

      stdout.strip
    end
    private_class_method :fetch_remote_url

    def self.parse_url(url)
      # Matches both SSH and HTTPS patterns:
      #   git@github.com:owner/repo.git     → owner, repo
      #   https://github.com/owner/repo.git → owner, repo
      #   https://github.com/owner/repo     → owner, repo
      if (match = url.match(%r{[/:]([\w.-]+)/([\w.-]+?)(?:\.git)?$}))
        "#{match[1]}/#{match[2]}"
      else
        raise NoRemoteError, "Cannot parse owner/repo from remote URL: #{url}"
      end
    end
    private_class_method :parse_url
  end
end
