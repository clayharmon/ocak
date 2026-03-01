# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Ocak::Config do
  let(:dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(dir) }

  def write_config(data)
    File.write(File.join(dir, 'ocak.yml'), YAML.dump(data))
  end

  describe '.load' do
    it 'raises ConfigNotFound when no ocak.yml exists' do
      expect { described_class.load(dir) }.to raise_error(Ocak::Config::ConfigNotFound)
    end

    it 'loads a valid config file' do
      write_config({ 'stack' => { 'language' => 'ruby' } })
      config = described_class.load(dir)
      expect(config.language).to eq('ruby')
    end
  end

  describe 'stack accessors' do
    subject(:config) { described_class.new(data, dir) }

    let(:data) do
      {
        stack: {
          language: 'ruby',
          framework: 'rails',
          test_command: 'bundle exec rspec',
          lint_command: 'bundle exec rubocop -A',
          security_commands: ['bundle exec brakeman -q']
        }
      }
    end

    it 'returns language' do
      expect(config.language).to eq('ruby')
    end

    it 'returns framework' do
      expect(config.framework).to eq('rails')
    end

    it 'returns test_command' do
      expect(config.test_command).to eq('bundle exec rspec')
    end

    it 'returns lint_command' do
      expect(config.lint_command).to eq('bundle exec rubocop -A')
    end

    it 'returns security_commands' do
      expect(config.security_commands).to eq(['bundle exec brakeman -q'])
    end

    it 'returns setup_command' do
      data_with_setup = data.merge(stack: data[:stack].merge(setup_command: 'bundle install'))
      config_with_setup = described_class.new(data_with_setup, dir)
      expect(config_with_setup.setup_command).to eq('bundle install')
    end
  end

  describe '#lint_check_command' do
    it 'strips -A from rubocop command' do
      config = described_class.new({ stack: { lint_command: 'bundle exec rubocop -A' } }, dir)
      expect(config.lint_check_command).to eq('bundle exec rubocop')
    end

    it 'strips --fix from eslint command' do
      config = described_class.new({ stack: { lint_command: 'npx eslint --fix .' } }, dir)
      expect(config.lint_check_command).to eq('npx eslint .')
    end

    it 'strips --write from biome command' do
      config = described_class.new({ stack: { lint_command: 'npx biome check --write' } }, dir)
      expect(config.lint_check_command).to eq('npx biome check')
    end

    it 'strips --allow-dirty from clippy command' do
      config = described_class.new({ stack: { lint_command: 'cargo clippy --fix --allow-dirty' } }, dir)
      expect(config.lint_check_command).to eq('cargo clippy')
    end

    it 'strips --unsafe-fix from ruff command' do
      config = described_class.new({ stack: { lint_command: 'ruff check --fix --unsafe-fix .' } }, dir)
      expect(config.lint_check_command).to eq('ruff check .')
    end

    it 'strips --fix-dry-run from eslint command' do
      config = described_class.new({ stack: { lint_command: 'npx eslint --fix-dry-run .' } }, dir)
      expect(config.lint_check_command).to eq('npx eslint .')
    end

    it 'strips --fix-type and its value from eslint command' do
      config = described_class.new({ stack: { lint_command: 'npx eslint --fix --fix-type suggestion .' } }, dir)
      expect(config.lint_check_command).to eq('npx eslint .')
    end

    it 'returns nil when no lint command configured' do
      config = described_class.new({}, dir)
      expect(config.lint_check_command).to be_nil
    end

    it 'returns explicit lint_check_command when configured' do
      config = described_class.new({
                                     stack: {
                                       lint_command: 'bundle exec rubocop -A',
                                       lint_check_command: 'bundle exec rubocop --parallel'
                                     }
                                   }, dir)
      expect(config.lint_check_command).to eq('bundle exec rubocop --parallel')
    end

    it 'prefers explicit lint_check_command over stripping' do
      config = described_class.new({
                                     stack: {
                                       lint_command: 'ruff check --fix --unsafe-fix .',
                                       lint_check_command: 'ruff check .'
                                     }
                                   }, dir)
      expect(config.lint_check_command).to eq('ruff check .')
    end

    it 'falls back to stripping when lint_check_command is empty string' do
      config = described_class.new({
                                     stack: {
                                       lint_command: 'bundle exec rubocop -A',
                                       lint_check_command: ''
                                     }
                                   }, dir)
      expect(config.lint_check_command).to eq('bundle exec rubocop')
    end

    it 'falls back to stripping when lint_check_command is not set' do
      config = described_class.new({ stack: { lint_command: 'bundle exec rubocop -A' } }, dir)
      expect(config.lint_check_command).to eq('bundle exec rubocop')
    end
  end

  describe 'pipeline defaults' do
    subject(:config) { described_class.new({}, dir) }

    it 'defaults max_parallel to 5' do
      expect(config.max_parallel).to eq(5)
    end

    it 'defaults poll_interval to 60' do
      expect(config.poll_interval).to eq(60)
    end

    it 'defaults worktree_dir' do
      expect(config.worktree_dir).to eq('.claude/worktrees')
    end

    it 'defaults log_dir' do
      expect(config.log_dir).to eq('logs/pipeline')
    end
  end

  describe 'label defaults' do
    subject(:config) { described_class.new({}, dir) }

    it 'defaults ready label' do
      expect(config.label_ready).to eq('auto-ready')
    end

    it 'defaults in_progress label' do
      expect(config.label_in_progress).to eq('auto-doing')
    end

    it 'defaults completed label' do
      expect(config.label_completed).to eq('completed')
    end

    it 'defaults failed label' do
      expect(config.label_failed).to eq('pipeline-failed')
    end

    it 'defaults reready label' do
      expect(config.label_reready).to eq('auto-reready')
    end

    it 'defaults awaiting_review label' do
      expect(config.label_awaiting_review).to eq('auto-pending-human')
    end
  end

  describe 'label overrides' do
    subject(:config) { described_class.new({ labels: { ready: 'queued', failed: 'broken' } }, dir) }

    it 'respects custom ready label' do
      expect(config.label_ready).to eq('queued')
    end

    it 'respects custom failed label' do
      expect(config.label_failed).to eq('broken')
    end

    it 'defaults unset labels' do
      expect(config.label_completed).to eq('completed')
    end

    it 'respects custom reready label' do
      config_with_reready = described_class.new({ labels: { reready: 'needs-work' } }, dir)
      expect(config_with_reready.label_reready).to eq('needs-work')
    end

    it 'respects custom awaiting_review label' do
      config_with_awaiting = described_class.new({ labels: { awaiting_review: 'pending' } }, dir)
      expect(config_with_awaiting.label_awaiting_review).to eq('pending')
    end

    it 'respects explicit in_progress override' do
      config_with_ip = described_class.new({ labels: { in_progress: 'in-progress' } }, dir)
      expect(config_with_ip.label_in_progress).to eq('in-progress')
    end
  end

  describe '#all_labels' do
    subject(:config) { described_class.new({}, dir) }

    it 'returns all configured labels' do
      expect(config.all_labels).to contain_exactly(
        'auto-ready', 'auto-doing', 'completed', 'pipeline-failed', 'auto-reready', 'auto-pending-human'
      )
    end
  end

  describe '#agent_path' do
    subject(:config) do
      described_class.new({
                            agents: { custom_agent: '.claude/agents/custom.md' }
                          }, '/project')
    end

    it 'returns custom path when configured' do
      expect(config.agent_path(:custom_agent)).to eq('/project/.claude/agents/custom.md')
    end

    it 'returns default path for unconfigured agents' do
      expect(config.agent_path(:implementer)).to eq('/project/.claude/agents/implementer.md')
    end

    it 'converts underscores to hyphens in default path' do
      expect(config.agent_path(:security_reviewer)).to eq('/project/.claude/agents/security-reviewer.md')
    end
  end

  describe '#steps' do
    it 'returns default steps when none configured' do
      config = described_class.new({}, dir)
      expect(config.steps.size).to eq(9)
      expect(config.steps.first).to include(agent: 'implementer', role: 'implement')
    end

    it 'includes audit step in default steps with full complexity' do
      config = described_class.new({}, dir)
      audit_step = config.steps.find { |s| s[:role] == 'audit' }
      expect(audit_step).to include(agent: 'auditor', role: 'audit', complexity: 'full')
    end

    it 'includes security step in default steps with full complexity' do
      config = described_class.new({}, dir)
      security_step = config.steps.find { |s| s[:role] == 'security' }
      expect(security_step).to include(agent: 'security-reviewer', role: 'security', complexity: 'full')
    end

    it 'returns configured steps' do
      data = { steps: [{ agent: 'implementer', role: 'implement' }] }
      config = described_class.new(data, dir)
      expect(config.steps.size).to eq(1)
    end
  end

  describe 'safety defaults' do
    subject(:config) { described_class.new({}, dir) }

    it 'defaults allowed_authors to empty array' do
      expect(config.allowed_authors).to eq([])
    end

    it 'defaults require_comment to nil' do
      expect(config.require_comment).to be_nil
    end

    it 'defaults max_issues_per_run to 5' do
      expect(config.max_issues_per_run).to eq(5)
    end

    it 'defaults cost_budget to nil' do
      expect(config.cost_budget).to be_nil
    end

    it 'defaults manual_review to false' do
      expect(config.manual_review).to be false
    end
  end

  describe 'safety overrides' do
    subject(:config) do
      described_class.new({
                            safety: {
                              allowed_authors: %w[alice bob],
                              require_comment: 'auto-ready',
                              max_issues_per_run: 10
                            }
                          }, dir)
    end

    it 'returns configured allowed_authors' do
      expect(config.allowed_authors).to eq(%w[alice bob])
    end

    it 'returns configured require_comment' do
      expect(config.require_comment).to eq('auto-ready')
    end

    it 'returns configured max_issues_per_run' do
      expect(config.max_issues_per_run).to eq(10)
    end
  end

  describe 'audit_mode' do
    it 'defaults to false' do
      config = described_class.new({}, dir)
      expect(config.audit_mode).to be false
    end

    it 'reads from pipeline config' do
      config = described_class.new({ pipeline: { audit_mode: true } }, dir)
      expect(config.audit_mode).to be true
    end

    it 'can be overridden' do
      config = described_class.new({}, dir)
      config.override(:audit_mode, true)
      expect(config.audit_mode).to be true
    end
  end

  describe 'manual_review' do
    it 'reads from pipeline config' do
      config = described_class.new({ pipeline: { manual_review: true } }, dir)
      expect(config.manual_review).to be true
    end

    it 'can be overridden' do
      config = described_class.new({}, dir)
      config.override(:manual_review, true)
      expect(config.manual_review).to be true
    end
  end

  describe 'path traversal validation' do
    describe '#worktree_dir' do
      it 'allows normal relative paths' do
        config = described_class.new({ pipeline: { worktree_dir: '.claude/worktrees' } }, dir)
        expect(config.worktree_dir).to eq('.claude/worktrees')
      end

      it 'raises ConfigError for path traversal' do
        config = described_class.new({ pipeline: { worktree_dir: '../../etc' } }, dir)
        expect { config.worktree_dir }.to raise_error(Ocak::Config::ConfigError, /escapes project directory/)
      end
    end

    describe '#log_dir' do
      it 'allows normal relative paths' do
        config = described_class.new({ pipeline: { log_dir: 'logs/pipeline' } }, dir)
        expect(config.log_dir).to eq('logs/pipeline')
      end

      it 'raises ConfigError for path traversal' do
        config = described_class.new({ pipeline: { log_dir: '../../../tmp/evil' } }, dir)
        expect { config.log_dir }.to raise_error(Ocak::Config::ConfigError, /escapes project directory/)
      end
    end

    describe '#agent_path' do
      it 'allows normal custom agent paths' do
        config = described_class.new({ agents: { custom: '.claude/agents/custom.md' } }, dir)
        expect(config.agent_path(:custom)).to eq(File.join(dir, '.claude/agents/custom.md'))
      end

      it 'raises ConfigError for custom path traversal' do
        config = described_class.new({ agents: { evil: '../../etc/passwd' } }, dir)
        expect { config.agent_path(:evil) }.to raise_error(Ocak::Config::ConfigError, /escapes project directory/)
      end

      it 'skips validation for default paths' do
        config = described_class.new({}, dir)
        expect(config.agent_path(:implementer)).to eq(File.join(dir, '.claude/agents/implementer.md'))
      end
    end
  end

  describe 'validation' do
    it 'raises on non-hash data' do
      expect { described_class.new('invalid', dir) }.to raise_error(Ocak::Config::ConfigError)
    end

    it 'accepts nil data' do
      config = described_class.new(nil, dir)
      expect(config.language).to eq('unknown')
    end
  end
end
