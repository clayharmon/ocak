# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Ocak::StackDetector do
  subject(:result) { described_class.new(dir).detect }

  let(:dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(dir) }

  def write_file(name, content = '')
    path = File.join(dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  context 'with a Ruby/Rails project' do
    before do
      write_file('Gemfile', <<~GEMFILE)
        source "https://rubygems.org"
        gem "rails", "~> 8.0"
        gem "rspec-rails"
        gem "rubocop"
        gem "brakeman"
        gem "bundler-audit"
      GEMFILE
    end

    it 'detects Ruby' do
      expect(result.language).to eq('ruby')
    end

    it 'detects Rails framework' do
      expect(result.framework).to eq('rails')
    end

    it 'detects rspec as test command' do
      expect(result.test_command).to eq('bundle exec rspec')
    end

    it 'detects rubocop as lint command' do
      expect(result.lint_command).to eq('bundle exec rubocop -A')
    end

    it 'detects security commands' do
      expect(result.security_commands).to include('bundle exec brakeman -q')
      expect(result.security_commands).to include('bundle exec bundler-audit check')
    end

    it 'returns nil for format_command (rubocop handles it)' do
      expect(result.format_command).to be_nil
    end
  end

  context 'with a Ruby/Sinatra project' do
    before do
      write_file('Gemfile', <<~GEMFILE)
        source "https://rubygems.org"
        gem "sinatra"
      GEMFILE
    end

    it 'detects Sinatra framework' do
      expect(result.framework).to eq('sinatra')
    end

    it 'defaults to rake test' do
      expect(result.test_command).to eq('bundle exec rake test')
    end
  end

  context 'with a TypeScript/React project' do
    before do
      write_file('package.json', JSON.generate(
                                   dependencies: { 'react' => '^19.0.0' },
                                   devDependencies: { '@biomejs/biome' => '^1.0', 'vitest' => '^1.0' }
                                 ))
      write_file('tsconfig.json', '{}')
    end

    it 'detects TypeScript' do
      expect(result.language).to eq('typescript')
    end

    it 'detects React framework' do
      expect(result.framework).to eq('react')
    end

    it 'detects vitest as test command' do
      expect(result.test_command).to eq('npx vitest run')
    end

    it 'detects biome as lint command' do
      expect(result.lint_command).to eq('npx biome check --write')
    end

    it 'has no separate format command (biome handles both)' do
      expect(result.format_command).to be_nil
    end

    it 'detects npm audit' do
      expect(result.security_commands).to include('npm audit --omit=dev')
    end
  end

  context 'with a Next.js project' do
    before do
      write_file('package.json', JSON.generate(
                                   dependencies: { 'next' => '^14.0', 'react' => '^19.0' },
                                   devDependencies: { 'eslint' => '^8.0', 'jest' => '^29.0' }
                                 ))
      write_file('tsconfig.json', '{}')
    end

    it 'detects Next.js framework' do
      expect(result.framework).to eq('next')
    end

    it 'detects jest as test command' do
      expect(result.test_command).to eq('npx jest')
    end

    it 'detects eslint as lint command' do
      expect(result.lint_command).to eq('npx eslint --fix .')
    end
  end

  context 'with a Python/Django project' do
    before do
      write_file('pyproject.toml', <<~TOML)
        [tool.pytest.ini_options]
        testpaths = ["tests"]
        [tool.ruff]
        line-length = 120
      TOML
      write_file('manage.py', '#!/usr/bin/env python')
    end

    it 'detects Python' do
      expect(result.language).to eq('python')
    end

    it 'detects Django framework' do
      expect(result.framework).to eq('django')
    end

    it 'detects pytest' do
      expect(result.test_command).to eq('pytest')
    end

    it 'detects ruff' do
      expect(result.lint_command).to eq('ruff check --fix .')
    end

    it 'detects ruff format' do
      expect(result.format_command).to eq('ruff format .')
    end
  end

  context 'with a Rust project' do
    before do
      write_file('Cargo.toml', <<~TOML)
        [package]
        name = "myproject"
        [dependencies]
        axum = "0.7"
      TOML
    end

    it 'detects Rust' do
      expect(result.language).to eq('rust')
    end

    it 'detects Axum framework' do
      expect(result.framework).to eq('axum')
    end

    it 'detects cargo test' do
      expect(result.test_command).to eq('cargo test')
    end

    it 'detects clippy' do
      expect(result.lint_command).to eq('cargo clippy --fix --allow-dirty')
    end

    it 'detects cargo fmt' do
      expect(result.format_command).to eq('cargo fmt')
    end
  end

  context 'with a Go project' do
    before do
      write_file('go.mod', <<~MOD)
        module github.com/user/project
        go 1.22
        require github.com/gin-gonic/gin v1.9.1
      MOD
    end

    it 'detects Go' do
      expect(result.language).to eq('go')
    end

    it 'detects Gin framework' do
      expect(result.framework).to eq('gin')
    end

    it 'detects go test' do
      expect(result.test_command).to eq('go test ./...')
    end
  end

  context 'with an empty directory' do
    it 'returns unknown language' do
      expect(result.language).to eq('unknown')
    end

    it 'returns nil framework' do
      expect(result.framework).to be_nil
    end

    it 'returns nil test command' do
      expect(result.test_command).to be_nil
    end
  end
end
