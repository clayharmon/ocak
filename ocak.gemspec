# frozen_string_literal: true

require_relative 'lib/ocak'

Gem::Specification.new do |spec|
  spec.name = 'ocak'
  spec.version = Ocak::VERSION
  spec.authors = ['Clay Harmon']
  spec.summary = 'Autonomous GitHub issue processing pipeline using Claude Code'
  spec.description = 'Ocak sets up and runs a multi-agent pipeline that autonomously ' \
                     'implements GitHub issues using Claude Code. Design issues, ' \
                     "run the pipeline, ship code. Let 'em cook."
  spec.homepage = 'https://github.com/clayharmon/ocak'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.4'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*', 'LICENSE.txt', 'README.md']
  spec.bindir = 'bin'
  spec.executables = ['ocak']
  spec.require_paths = ['lib']

  spec.add_dependency 'dry-cli', '~> 1.0'
end
