# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'

RSpec.describe Ocak::MonorepoDetector do
  # Minimal host class that includes MonorepoDetector and provides the helpers
  # it depends on (exists?, read_file) — same as StackDetector does.
  let(:host_class) do
    Class.new do
      include Ocak::MonorepoDetector

      def initialize(dir)
        @dir = dir
      end

      # Expose private methods for testing
      public :detect_monorepo, :detect_npm_workspaces, :detect_pnpm_workspaces,
             :detect_cargo_workspaces, :detect_go_workspaces, :detect_lerna_packages,
             :detect_convention_packages, :expand_workspace_globs

      private

      def exists?(filename) = File.exist?(File.join(@dir, filename))

      def read_file(filename)
        path = File.join(@dir, filename)
        File.exist?(path) ? File.read(path) : ''
      end
    end
  end

  subject(:detector) { host_class.new(dir) }

  let(:dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(dir) }

  def write_file(name, content = '')
    path = File.join(dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  describe '#detect_npm_workspaces' do
    it 'returns packages matching workspaces array globs' do
      write_file('package.json', JSON.generate(workspaces: ['packages/*']))
      write_file('packages/core/package.json', '{}')
      write_file('packages/web/package.json', '{}')

      expect(detector.detect_npm_workspaces).to contain_exactly('packages/core', 'packages/web')
    end

    it 'handles workspaces.packages hash form' do
      write_file('package.json', JSON.generate(workspaces: { packages: ['libs/*'] }))
      write_file('libs/utils/index.js', '')
      write_file('libs/shared/index.js', '')

      expect(detector.detect_npm_workspaces).to contain_exactly('libs/utils', 'libs/shared')
    end

    it 'returns empty when package.json has no workspaces key' do
      write_file('package.json', JSON.generate(name: 'solo'))

      expect(detector.detect_npm_workspaces).to eq([])
    end

    it 'returns empty when workspaces array is empty' do
      write_file('package.json', JSON.generate(workspaces: []))

      expect(detector.detect_npm_workspaces).to eq([])
    end

    it 'returns empty when package.json does not exist' do
      expect(detector.detect_npm_workspaces).to eq([])
    end

    it 'returns empty when package.json is malformed JSON' do
      write_file('package.json', '{ not valid json }}}')

      expect { detector.detect_npm_workspaces }.to output(/Failed to parse/).to_stderr
      expect(detector.detect_npm_workspaces).to eq([])
    end

    it 'returns empty when workspaces value is a string (unexpected type)' do
      write_file('package.json', JSON.generate(workspaces: 'packages/*'))

      expect(detector.detect_npm_workspaces).to eq([])
    end
  end

  describe '#detect_pnpm_workspaces' do
    it 'detects packages from pnpm-workspace.yaml' do
      write_file('pnpm-workspace.yaml', <<~YAML)
        packages:
          - 'packages/*'
      YAML
      write_file('packages/ui/package.json', '{}')
      write_file('packages/api/package.json', '{}')

      expect(detector.detect_pnpm_workspaces).to contain_exactly('packages/ui', 'packages/api')
    end

    it 'handles entries without quotes' do
      write_file('pnpm-workspace.yaml', <<~YAML)
        packages:
          - apps/*
      YAML
      write_file('apps/web/index.ts', '')
      write_file('apps/mobile/index.ts', '')

      expect(detector.detect_pnpm_workspaces).to contain_exactly('apps/web', 'apps/mobile')
    end

    it 'returns empty when file does not exist' do
      expect(detector.detect_pnpm_workspaces).to eq([])
    end

    it 'returns empty when no globs match any directories' do
      write_file('pnpm-workspace.yaml', <<~YAML)
        packages:
          - 'nonexistent/*'
      YAML

      expect(detector.detect_pnpm_workspaces).to eq([])
    end
  end

  describe '#detect_cargo_workspaces' do
    it 'detects members from Cargo.toml workspace' do
      write_file('Cargo.toml', <<~TOML)
        [workspace]
        members = ["crates/core", "crates/api"]
      TOML
      FileUtils.mkdir_p(File.join(dir, 'crates', 'core'))
      FileUtils.mkdir_p(File.join(dir, 'crates', 'api'))

      expect(detector.detect_cargo_workspaces).to contain_exactly('crates/core', 'crates/api')
    end

    it 'expands glob patterns in members' do
      write_file('Cargo.toml', <<~TOML)
        [workspace]
        members = ["crates/*"]
      TOML
      FileUtils.mkdir_p(File.join(dir, 'crates', 'lib-a'))
      FileUtils.mkdir_p(File.join(dir, 'crates', 'lib-b'))

      expect(detector.detect_cargo_workspaces).to contain_exactly('crates/lib-a', 'crates/lib-b')
    end

    it 'returns empty when Cargo.toml does not exist' do
      expect(detector.detect_cargo_workspaces).to eq([])
    end

    it 'returns empty when Cargo.toml has no [workspace] section' do
      write_file('Cargo.toml', <<~TOML)
        [package]
        name = "solo-crate"
      TOML

      expect(detector.detect_cargo_workspaces).to eq([])
    end

    it 'returns empty when members list is empty' do
      write_file('Cargo.toml', <<~TOML)
        [workspace]
        members = []
      TOML

      expect(detector.detect_cargo_workspaces).to eq([])
    end
  end

  describe '#detect_go_workspaces' do
    it 'detects packages from go.work use directives' do
      write_file('go.work', <<~GOWORK)
        go 1.22

        use ./svc/auth
        use ./svc/gateway
      GOWORK
      FileUtils.mkdir_p(File.join(dir, 'svc', 'auth'))
      FileUtils.mkdir_p(File.join(dir, 'svc', 'gateway'))

      expect(detector.detect_go_workspaces).to contain_exactly('./svc/auth', './svc/gateway')
    end

    it 'excludes use directives whose directories do not exist' do
      write_file('go.work', <<~GOWORK)
        go 1.22

        use ./exists
        use ./missing
      GOWORK
      FileUtils.mkdir_p(File.join(dir, 'exists'))

      expect(detector.detect_go_workspaces).to eq(['./exists'])
    end

    it 'returns empty when go.work does not exist' do
      expect(detector.detect_go_workspaces).to eq([])
    end
  end

  describe '#detect_lerna_packages' do
    it 'detects packages from lerna.json packages field' do
      write_file('lerna.json', JSON.generate(packages: ['modules/*']))
      write_file('modules/auth/package.json', '{}')
      write_file('modules/core/package.json', '{}')

      expect(detector.detect_lerna_packages).to contain_exactly('modules/auth', 'modules/core')
    end

    it 'falls back to packages/* when packages key is absent' do
      write_file('lerna.json', JSON.generate(version: '1.0.0'))
      write_file('packages/foo/package.json', '{}')
      write_file('packages/bar/package.json', '{}')

      expect(detector.detect_lerna_packages).to contain_exactly('packages/foo', 'packages/bar')
    end

    it 'returns empty when lerna.json does not exist' do
      expect(detector.detect_lerna_packages).to eq([])
    end

    it 'returns empty when lerna.json is malformed JSON' do
      write_file('lerna.json', '{ bad json')

      expect { detector.detect_lerna_packages }.to output(/Failed to parse/).to_stderr
      # Falls back to default packages/*
      expect(detector.detect_lerna_packages).to eq([])
    end
  end

  describe '#detect_convention_packages' do
    it 'detects subdirectories under conventional directory names' do
      FileUtils.mkdir_p(File.join(dir, 'packages', 'a'))
      FileUtils.mkdir_p(File.join(dir, 'packages', 'b'))

      expect(detector.detect_convention_packages).to contain_exactly('packages/a', 'packages/b')
    end

    it 'detects apps/ convention' do
      FileUtils.mkdir_p(File.join(dir, 'apps', 'web'))
      FileUtils.mkdir_p(File.join(dir, 'apps', 'api'))

      expect(detector.detect_convention_packages).to contain_exactly('apps/web', 'apps/api')
    end

    it 'skips directories with only one subdirectory' do
      FileUtils.mkdir_p(File.join(dir, 'packages', 'only-one'))

      expect(detector.detect_convention_packages).to eq([])
    end

    it 'skips hidden subdirectories' do
      FileUtils.mkdir_p(File.join(dir, 'packages', '.hidden'))
      FileUtils.mkdir_p(File.join(dir, 'packages', 'visible'))

      # Only one non-hidden subdir, so it's skipped
      expect(detector.detect_convention_packages).to eq([])
    end

    it 'returns empty when no convention directories exist' do
      expect(detector.detect_convention_packages).to eq([])
    end

    it 'detects multiple convention directories' do
      FileUtils.mkdir_p(File.join(dir, 'packages', 'a'))
      FileUtils.mkdir_p(File.join(dir, 'packages', 'b'))
      FileUtils.mkdir_p(File.join(dir, 'libs', 'x'))
      FileUtils.mkdir_p(File.join(dir, 'libs', 'y'))

      result = detector.detect_convention_packages
      expect(result).to include('packages/a', 'packages/b', 'libs/x', 'libs/y')
    end
  end

  describe '#expand_workspace_globs' do
    it 'expands glob patterns to matching directories' do
      FileUtils.mkdir_p(File.join(dir, 'src', 'alpha'))
      FileUtils.mkdir_p(File.join(dir, 'src', 'beta'))

      expect(detector.expand_workspace_globs(['src/*'])).to contain_exactly('src/alpha', 'src/beta')
    end

    it 'ignores files (only returns directories)' do
      FileUtils.mkdir_p(File.join(dir, 'src', 'pkg'))
      File.write(File.join(dir, 'src', 'README.md'), '')

      expect(detector.expand_workspace_globs(['src/*'])).to eq(['src/pkg'])
    end

    it 'returns empty for globs that match nothing' do
      expect(detector.expand_workspace_globs(['nonexistent/*'])).to eq([])
    end

    it 'handles multiple globs' do
      FileUtils.mkdir_p(File.join(dir, 'packages', 'core'))
      FileUtils.mkdir_p(File.join(dir, 'apps', 'web'))

      result = detector.expand_workspace_globs(['packages/*', 'apps/*'])
      expect(result).to contain_exactly('packages/core', 'apps/web')
    end
  end

  describe '#detect_monorepo' do
    it 'returns detected: true with packages when workspaces are found' do
      write_file('package.json', JSON.generate(workspaces: ['packages/*']))
      write_file('packages/a/package.json', '{}')
      write_file('packages/b/package.json', '{}')

      result = detector.detect_monorepo
      expect(result[:detected]).to be true
      expect(result[:packages]).to contain_exactly('packages/a', 'packages/b')
    end

    it 'returns detected: false with empty packages when nothing is found' do
      result = detector.detect_monorepo
      expect(result[:detected]).to be false
      expect(result[:packages]).to eq([])
    end

    it 'deduplicates packages across detectors' do
      write_file('package.json', JSON.generate(workspaces: ['packages/*']))
      write_file('lerna.json', JSON.generate(packages: ['packages/*']))
      write_file('packages/a/package.json', '{}')
      write_file('packages/b/package.json', '{}')

      result = detector.detect_monorepo
      expect(result[:packages]).to contain_exactly('packages/a', 'packages/b')
    end

    it 'skips convention detection when other detectors find packages' do
      write_file('package.json', JSON.generate(workspaces: ['libs/*']))
      write_file('libs/core/package.json', '{}')
      write_file('libs/utils/package.json', '{}')
      # apps/ would be detected by convention but should be skipped
      FileUtils.mkdir_p(File.join(dir, 'apps', 'web'))
      FileUtils.mkdir_p(File.join(dir, 'apps', 'api'))

      result = detector.detect_monorepo
      expect(result[:packages]).to contain_exactly('libs/core', 'libs/utils')
    end
  end
end
