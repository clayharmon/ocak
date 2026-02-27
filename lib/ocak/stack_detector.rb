# frozen_string_literal: true

require 'json'

module Ocak
  class StackDetector
    Result = Struct.new(:language, :framework, :test_command, :lint_command,
                        :format_command, :security_commands, :setup_command)

    def initialize(project_dir)
      @dir = project_dir
    end

    def detect
      lang = detect_language
      Result.new(
        language: lang,
        framework: detect_framework(lang),
        test_command: detect_test_command(lang),
        lint_command: detect_lint_command(lang),
        format_command: detect_format_command(lang),
        security_commands: detect_security_commands(lang),
        setup_command: detect_setup_command(lang)
      )
    end

    private

    def detect_language
      return 'ruby'       if exists?('Gemfile')
      return 'typescript' if exists?('tsconfig.json')
      return 'javascript' if exists?('package.json')
      return 'python'     if exists?('pyproject.toml') || exists?('setup.py') || exists?('requirements.txt')
      return 'rust'       if exists?('Cargo.toml')
      return 'go'         if exists?('go.mod')
      return 'java'       if exists?('pom.xml') || exists?('build.gradle')
      return 'elixir'     if exists?('mix.exs')

      'unknown'
    end

    def detect_framework(lang)
      case lang
      when 'ruby' then detect_ruby_framework
      when 'typescript', 'javascript' then detect_js_framework
      when 'python'     then detect_python_framework
      when 'rust'       then detect_rust_framework
      when 'go'         then detect_go_framework
      when 'elixir'     then 'phoenix' if gemfile_has?('mix.exs', 'phoenix')
      end
    end

    def detect_test_command(lang)
      case lang
      when 'ruby'
        gemfile_has?('Gemfile', 'rspec') ? 'bundle exec rspec' : 'bundle exec rake test'
      when 'typescript', 'javascript'
        return 'npx vitest run' if pkg_has?('vitest')
        return 'npx jest'       if pkg_has?('jest')

        'npm test'
      when 'python'
        return 'pytest' if exists?('pyproject.toml') && read_file('pyproject.toml').include?('pytest')

        'python -m pytest'
      when 'rust'  then 'cargo test'
      when 'go'    then 'go test ./...'
      when 'java'  then exists?('gradlew') ? './gradlew test' : 'mvn test'
      when 'elixir' then 'mix test'
      end
    end

    def detect_lint_command(lang)
      case lang
      when 'ruby'
        'bundle exec rubocop -A' if gemfile_has?('Gemfile', 'rubocop')
      when 'typescript', 'javascript'
        return 'npx biome check --write' if pkg_has?('biome') || pkg_has?('@biomejs/biome')

        'npx eslint --fix .' if pkg_has?('eslint')
      when 'python'
        return 'ruff check --fix .' if exists?('pyproject.toml') && read_file('pyproject.toml').include?('ruff')

        'flake8'
      when 'rust'   then 'cargo clippy --fix --allow-dirty'
      when 'go'     then 'golangci-lint run'
      when 'elixir' then 'mix credo'
      end
    end

    def detect_format_command(lang)
      case lang
      when 'ruby' then nil # rubocop handles formatting
      when 'typescript', 'javascript'
        return nil if pkg_has?('biome') || pkg_has?('@biomejs/biome') # biome handles both

        'npx prettier --write .' if pkg_has?('prettier')
      when 'python'
        return 'ruff format .' if exists?('pyproject.toml') && read_file('pyproject.toml').include?('ruff')

        'black .' if exists?('pyproject.toml') && read_file('pyproject.toml').include?('black')
      when 'rust'   then 'cargo fmt'
      when 'go'     then 'gofmt -w .'
      when 'elixir' then 'mix format'
      end
    end

    def detect_security_commands(lang)
      cmds = []
      case lang
      when 'ruby'
        cmds << 'bundle exec brakeman -q' if gemfile_has?('Gemfile', 'brakeman')
        cmds << 'bundle exec bundler-audit check' if gemfile_has?('Gemfile', 'bundler-audit')
      when 'typescript', 'javascript'
        cmds << 'npm audit --omit=dev'
      when 'python'
        cmds << 'bandit -r .' if exists?('pyproject.toml') && read_file('pyproject.toml').include?('bandit')
        cmds << 'safety check' if exists?('pyproject.toml') && read_file('pyproject.toml').include?('safety')
      when 'rust'
        cmds << 'cargo audit' if read_file('Cargo.toml').include?('cargo-audit')
      when 'go'
        cmds << 'gosec ./...'
      end
      cmds
    end

    def detect_setup_command(lang)
      case lang
      when 'ruby' then 'bundle install' if exists?('Gemfile')
      when 'typescript', 'javascript' then detect_js_setup_command
      when 'python' then detect_python_setup_command
      when 'rust' then 'cargo fetch' if exists?('Cargo.toml')
      when 'go' then 'go mod download' if exists?('go.mod')
      when 'elixir' then 'mix deps.get' if exists?('mix.exs')
      when 'java' then detect_java_setup_command
      end
    end

    def detect_js_setup_command
      return 'npm install' if exists?('package-lock.json')
      return 'yarn install' if exists?('yarn.lock')
      return 'pnpm install' if exists?('pnpm-lock.yaml')

      'npm install' if exists?('package.json')
    end

    def detect_python_setup_command
      return 'pip install -e .' if exists?('pyproject.toml')

      'pip install -r requirements.txt' if exists?('requirements.txt')
    end

    def detect_java_setup_command
      return './gradlew dependencies' if exists?('gradlew')

      'mvn dependency:resolve' if exists?('pom.xml')
    end

    # Framework detection helpers

    def detect_ruby_framework
      return 'rails'   if gemfile_has?('Gemfile', 'rails')
      return 'sinatra' if gemfile_has?('Gemfile', 'sinatra')
      return 'hanami'  if gemfile_has?('Gemfile', 'hanami')

      nil
    end

    def detect_js_framework
      return 'next'    if pkg_has?('next')
      return 'remix'   if pkg_has?('@remix-run/react')
      return 'nuxt'    if pkg_has?('nuxt')
      return 'svelte'  if pkg_has?('svelte') || pkg_has?('@sveltejs/kit')
      return 'react'   if pkg_has?('react')
      return 'vue'     if pkg_has?('vue')
      return 'express' if pkg_has?('express')

      nil
    end

    def detect_python_framework
      return 'django' if exists?('manage.py') || pip_has?('django')
      return 'flask'  if pip_has?('flask')
      return 'fastapi' if pip_has?('fastapi')

      nil
    end

    def detect_rust_framework
      content = read_file('Cargo.toml')
      return 'actix'  if content.include?('actix-web')
      return 'axum'   if content.include?('axum')
      return 'rocket' if content.include?('rocket')

      nil
    end

    def detect_go_framework
      content = read_file('go.mod')
      return 'gin'   if content.include?('gin-gonic')
      return 'echo'  if content.include?('labstack/echo')
      return 'fiber' if content.include?('gofiber/fiber')
      return 'chi'   if content.include?('go-chi/chi')

      nil
    end

    # File helpers

    def exists?(filename)
      File.exist?(File.join(@dir, filename))
    end

    def read_file(filename)
      path = File.join(@dir, filename)
      File.exist?(path) ? File.read(path) : ''
    end

    def gemfile_has?(file, gem_name)
      read_file(file).match?(/['"]#{Regexp.escape(gem_name)}[\w-]*['"]/)
    end

    def pkg_has?(package)
      @pkg_json ||= begin
        raw = read_file('package.json')
        raw.empty? ? {} : JSON.parse(raw)
      rescue JSON::ParserError
        {}
      end

      deps = (@pkg_json['dependencies'] || {}).merge(@pkg_json['devDependencies'] || {})
      deps.key?(package)
    end

    def pip_has?(package)
      %w[pyproject.toml setup.py requirements.txt].any? do |f|
        read_file(f).downcase.include?(package.downcase)
      end
    end
  end
end
