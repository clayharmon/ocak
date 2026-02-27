# frozen_string_literal: true

require 'json'
require_relative 'monorepo_detector'

module Ocak
  class StackDetector
    include MonorepoDetector

    Result = Struct.new(:language, :framework, :test_command, :lint_command,
                        :format_command, :security_commands, :setup_command,
                        :monorepo, :packages)
    LANGUAGE_RULES = [
      ['ruby',       ['Gemfile']],
      ['typescript', ['tsconfig.json']],
      ['javascript', ['package.json']],
      ['python',     ['pyproject.toml', 'setup.py', 'requirements.txt']],
      ['rust',       ['Cargo.toml']],
      ['go',         ['go.mod']],
      ['java',       ['pom.xml', 'build.gradle']],
      ['elixir',     ['mix.exs']]
    ].freeze
    FRAMEWORK_RULES = {
      'ruby' => [
        [:dep_in_file, 'Gemfile', 'rails', 'rails'],
        [:dep_in_file, 'Gemfile', 'sinatra', 'sinatra'],
        [:dep_in_file, 'Gemfile', 'hanami', 'hanami']
      ],
      'javascript' => [
        [:pkg_has, 'next', 'next'], [:pkg_has, '@remix-run/react', 'remix'],
        [:pkg_has, 'nuxt', 'nuxt'], [:pkg_has, 'svelte', 'svelte'],
        [:pkg_has, '@sveltejs/kit', 'svelte'], [:pkg_has, 'react', 'react'],
        [:pkg_has, 'vue', 'vue'], [:pkg_has, 'express', 'express']
      ],
      'python' => [
        [:file_exists, 'manage.py', 'django'], [:pip_has, 'django', 'django'],
        [:pip_has, 'flask', 'flask'], [:pip_has, 'fastapi', 'fastapi']
      ],
      'rust' => [
        [:file_contains, 'Cargo.toml', 'actix-web', 'actix'],
        [:file_contains, 'Cargo.toml', 'axum', 'axum'],
        [:file_contains, 'Cargo.toml', 'rocket', 'rocket']
      ],
      'go' => [
        [:file_contains, 'go.mod', 'gin-gonic', 'gin'],
        [:file_contains, 'go.mod', 'labstack/echo', 'echo'],
        [:file_contains, 'go.mod', 'gofiber/fiber', 'fiber'],
        [:file_contains, 'go.mod', 'go-chi/chi', 'chi']
      ],
      'elixir' => [[:dep_in_file, 'mix.exs', 'phoenix', 'phoenix']]
    }.freeze
    TOOL_RULES = {
      test: {
        'ruby' => [
          [:dep_in_file, 'Gemfile', 'rspec', 'bundle exec rspec'],
          [:always, 'bundle exec rake test']
        ],
        'javascript' => [
          [:pkg_has, 'vitest', 'npx vitest run'],
          [:pkg_has, 'jest', 'npx jest'],
          [:always, 'npm test']
        ],
        'python' => [
          [:file_contains, 'pyproject.toml', 'pytest', 'pytest'],
          [:always, 'python -m pytest']
        ],
        'rust' => [[:always, 'cargo test']],
        'go' => [[:always, 'go test ./...']],
        'java' => [[:file_exists, 'gradlew', './gradlew test'], [:always, 'mvn test']],
        'elixir' => [[:always, 'mix test']]
      },
      lint: {
        'ruby' => [[:dep_in_file, 'Gemfile', 'rubocop', 'bundle exec rubocop -A']],
        'javascript' => [
          [:pkg_has, 'biome', 'npx biome check --write'],
          [:pkg_has, '@biomejs/biome', 'npx biome check --write'],
          [:pkg_has, 'eslint', 'npx eslint --fix .']
        ],
        'python' => [
          [:file_contains, 'pyproject.toml', 'ruff', 'ruff check --fix .'],
          [:always, 'flake8']
        ],
        'rust' => [[:always, 'cargo clippy --fix --allow-dirty']],
        'go' => [[:always, 'golangci-lint run']],
        'elixir' => [[:always, 'mix credo']]
      },
      format: {
        'javascript' => [
          [:pkg_has, 'biome', nil],
          [:pkg_has, '@biomejs/biome', nil],
          [:pkg_has, 'prettier', 'npx prettier --write .']
        ],
        'python' => [
          [:file_contains, 'pyproject.toml', 'ruff', 'ruff format .'],
          [:file_contains, 'pyproject.toml', 'black', 'black .']
        ],
        'rust' => [[:always, 'cargo fmt']],
        'go' => [[:always, 'gofmt -w .']],
        'elixir' => [[:always, 'mix format']]
      },
      security: {
        'ruby' => [
          [:dep_in_file, 'Gemfile', 'brakeman', 'bundle exec brakeman -q'],
          [:dep_in_file, 'Gemfile', 'bundler-audit', 'bundle exec bundler-audit check']
        ],
        'javascript' => [[:always, 'npm audit --omit=dev']],
        'python' => [
          [:file_contains, 'pyproject.toml', 'bandit', 'bandit -r .'],
          [:file_contains, 'pyproject.toml', 'safety', 'safety check']
        ],
        'rust' => [[:file_contains, 'Cargo.toml', 'cargo-audit', 'cargo audit']],
        'go' => [[:always, 'gosec ./...']]
      },
      setup: {
        'ruby' => [[:file_exists, 'Gemfile', 'bundle install']],
        'javascript' => [
          [:file_exists, 'package-lock.json', 'npm install'],
          [:file_exists, 'yarn.lock', 'yarn install'],
          [:file_exists, 'pnpm-lock.yaml', 'pnpm install'],
          [:file_exists, 'package.json', 'npm install']
        ],
        'python' => [
          [:file_exists, 'pyproject.toml', 'pip install -e .'],
          [:file_exists, 'requirements.txt', 'pip install -r requirements.txt']
        ],
        'rust' => [[:file_exists, 'Cargo.toml', 'cargo fetch']],
        'go' => [[:file_exists, 'go.mod', 'go mod download']],
        'elixir' => [[:file_exists, 'mix.exs', 'mix deps.get']],
        'java' => [
          [:file_exists, 'gradlew', './gradlew dependencies'],
          [:file_exists, 'pom.xml', 'mvn dependency:resolve']
        ]
      }
    }.freeze

    def initialize(project_dir)
      @dir = project_dir
    end

    def detect
      lang = detect_language
      key = rules_key(lang)
      mono = detect_monorepo
      Result.new(
        language: lang,
        framework: first_match(FRAMEWORK_RULES[key]),
        test_command: first_match(TOOL_RULES[:test][key]),
        lint_command: first_match(TOOL_RULES[:lint][key]),
        format_command: first_match(TOOL_RULES[:format][key]),
        security_commands: all_matches(TOOL_RULES[:security][key]),
        setup_command: first_match(TOOL_RULES[:setup][key]),
        monorepo: mono[:detected],
        packages: mono[:packages]
      )
    end

    private

    def detect_language
      LANGUAGE_RULES.each { |lang, files| return lang if files.any? { |f| exists?(f) } }
      'unknown'
    end

    def rules_key(lang) = lang == 'typescript' ? 'javascript' : lang
    def first_match(rules) = rules&.find { |rule| match_rule?(rule) }&.last
    def all_matches(rules) = (rules || []).filter_map { |rule| rule.last if match_rule?(rule) }

    def match_rule?(rule)
      case rule.first
      when :dep_in_file   then gemfile_has?(rule[1], rule[2])
      when :pkg_has       then pkg_has?(rule[1])
      when :pip_has       then pip_has?(rule[1])
      when :file_contains then read_file(rule[1]).include?(rule[2])
      when :file_exists   then exists?(rule[1])
      when :always        then true
      end
    end

    def exists?(filename) = File.exist?(File.join(@dir, filename))
    def read_file(filename) = File.join(@dir, filename).then { |p| File.exist?(p) ? File.read(p) : '' }
    def gemfile_has?(file, gem_name) = read_file(file).match?(/['"]#{Regexp.escape(gem_name)}[\w-]*['"]/)

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
