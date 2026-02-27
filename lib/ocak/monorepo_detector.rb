# frozen_string_literal: true

require 'json'

module Ocak
  module MonorepoDetector
    private

    def detect_monorepo
      packages = []
      packages.concat(detect_npm_workspaces)
      packages.concat(detect_pnpm_workspaces)
      packages.concat(detect_cargo_workspaces)
      packages.concat(detect_go_workspaces)
      packages.concat(detect_lerna_packages)
      packages.concat(detect_convention_packages) if packages.empty?
      packages.uniq!
      { detected: packages.any?, packages: packages }
    end

    def detect_npm_workspaces
      return [] unless exists?('package.json')

      pkg = begin
        JSON.parse(read_file('package.json'))
      rescue JSON::ParserError => e
        warn("Failed to parse package.json: #{e.message}")
        {}
      end
      workspaces = pkg['workspaces']
      workspaces = workspaces['packages'] if workspaces.is_a?(Hash)
      return [] unless workspaces.is_a?(Array) && workspaces.any?

      expand_workspace_globs(workspaces)
    end

    def detect_pnpm_workspaces
      return [] unless exists?('pnpm-workspace.yaml')

      content = read_file('pnpm-workspace.yaml')
      globs = content.scan(/^\s*-\s*['"]?([^'"#\n]+)/).flatten.map(&:strip)
      expand_workspace_globs(globs)
    end

    def detect_cargo_workspaces
      return [] unless exists?('Cargo.toml') && read_file('Cargo.toml').include?('[workspace]')

      read_file('Cargo.toml').scan(/members\s*=\s*\[(.*?)\]/m).flatten.flat_map do |members|
        globs = members.scan(/"([^"]+)"/).flatten
        expand_workspace_globs(globs)
      end
    end

    def detect_go_workspaces
      return [] unless exists?('go.work')

      read_file('go.work').scan(/use\s+(\S+)/).flatten.select do |pkg|
        Dir.exist?(File.join(@dir, pkg))
      end
    end

    def detect_lerna_packages
      return [] unless exists?('lerna.json')

      lerna = begin
        JSON.parse(read_file('lerna.json'))
      rescue JSON::ParserError => e
        warn("Failed to parse lerna.json: #{e.message}")
        {}
      end
      expand_workspace_globs(lerna['packages'] || ['packages/*'])
    end

    def detect_convention_packages
      packages = []
      %w[packages apps services modules libs].each do |candidate|
        path = File.join(@dir, candidate)
        next unless Dir.exist?(path)

        subdirs = Dir.entries(path).reject { |e| e.start_with?('.') }.select do |e|
          File.directory?(File.join(path, e))
        end
        packages.concat(subdirs.map { |s| "#{candidate}/#{s}" }) if subdirs.size > 1
      end
      packages
    end

    def expand_workspace_globs(globs)
      globs.flat_map do |glob|
        pattern = File.join(@dir, glob)
        Dir.glob(pattern).select { |p| File.directory?(p) }.map do |p|
          p.sub("#{@dir}/", '')
        end
      end
    end
  end
end
