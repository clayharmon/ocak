# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Ocak::TargetResolver do
  # Use unverified double since multi_repo?, target_field, repos, resolve_repo
  # are added by a dependency issue and not yet on Ocak::Config
  let(:config) do
    double(
      'Config',
      multi_repo?: true,
      target_field: 'target_repo',
      repos: { 'my-gem' => '/dev/my-gem', 'other-gem' => '/dev/other-gem' }
    )
  end

  let(:issue) do
    {
      'number' => 42,
      'body' => "---\ntarget_repo: my-gem\n---\n\n## Description\nUpdate the gem."
    }
  end

  describe '.resolve' do
    context 'when multi-repo is disabled' do
      before { allow(config).to receive(:multi_repo?).and_return(false) }

      it 'returns nil' do
        expect(described_class.resolve(issue, config: config)).to be_nil
      end
    end

    context 'when multi-repo is enabled' do
      context 'with valid YAML front-matter containing the target field' do
        before do
          allow(config).to receive(:resolve_repo).with('my-gem').and_return({ name: 'my-gem', path: '/dev/my-gem' })
        end

        it 'returns a hash with name and path' do
          result = described_class.resolve(issue, config: config)

          expect(result).to eq({ name: 'my-gem', path: '/dev/my-gem' })
        end

        it 'delegates to config.resolve_repo with the extracted name' do
          described_class.resolve(issue, config: config)

          expect(config).to have_received(:resolve_repo).with('my-gem')
        end
      end

      context 'when the issue body has no front-matter' do
        let(:issue) { { 'number' => 42, 'body' => '## Description\nNo front-matter here.' } }

        it 'raises TargetResolutionError' do
          expect { described_class.resolve(issue, config: config) }
            .to raise_error(Ocak::TargetResolver::TargetResolutionError, /missing required 'target_repo'/)
        end

        it 'includes the issue number in the error message' do
          expect { described_class.resolve(issue, config: config) }
            .to raise_error(Ocak::TargetResolver::TargetResolutionError, /Issue #42/)
        end

        it 'includes known repos in the error message' do
          expect { described_class.resolve(issue, config: config) }
            .to raise_error(Ocak::TargetResolver::TargetResolutionError, /my-gem/)
        end
      end

      context 'when the front-matter is present but missing the target field' do
        let(:issue) { { 'number' => 42, 'body' => "---\nother_field: value\n---\n\n## Description" } }

        it 'raises TargetResolutionError' do
          expect { described_class.resolve(issue, config: config) }
            .to raise_error(Ocak::TargetResolver::TargetResolutionError, /missing required 'target_repo'/)
        end
      end

      context 'when issue body is nil' do
        let(:issue) { { 'number' => 42, 'body' => nil } }

        it 'raises TargetResolutionError' do
          expect { described_class.resolve(issue, config: config) }
            .to raise_error(Ocak::TargetResolver::TargetResolutionError)
        end
      end

      context 'when config.resolve_repo raises an error for unknown repo' do
        before do
          allow(config).to receive(:resolve_repo).with('unknown-gem')
                                                 .and_raise(StandardError, 'Unknown repo: unknown-gem')
        end

        let(:issue) { { 'number' => 42, 'body' => "---\ntarget_repo: unknown-gem\n---" } }

        it 'propagates the error from config.resolve_repo' do
          expect { described_class.resolve(issue, config: config) }
            .to raise_error(StandardError, /Unknown repo: unknown-gem/)
        end
      end
    end
  end

  describe '.extract_target_name' do
    context 'with valid front-matter containing the target field' do
      it 'returns the target name string' do
        body = "---\ntarget_repo: my-gem\n---\n\n## Description"

        expect(described_class.extract_target_name(body, field: 'target_repo')).to eq('my-gem')
      end
    end

    context 'with no front-matter' do
      it 'returns nil' do
        body = '## Description\nNo front-matter here.'

        expect(described_class.extract_target_name(body, field: 'target_repo')).to be_nil
      end
    end

    context 'with malformed YAML front-matter' do
      it 'returns nil when Psych::SyntaxError is raised' do
        body = "---\n: invalid: yaml: here\n---"

        expect(described_class.extract_target_name(body, field: 'target_repo')).to be_nil
      end
    end

    context 'when front-matter is not at the start of body' do
      it 'returns nil' do
        body = "Some text first\n---\ntarget_repo: my-gem\n---"

        expect(described_class.extract_target_name(body, field: 'target_repo')).to be_nil
      end
    end

    context 'with extra whitespace in the value' do
      it 'strips whitespace from the name' do
        body = "---\ntarget_repo:   my-gem   \n---"

        expect(described_class.extract_target_name(body, field: 'target_repo')).to eq('my-gem')
      end
    end

    context 'with front-matter containing extra fields' do
      it 'extracts only the requested field' do
        body = "---\nauthor: someone\ntarget_repo: my-gem\nversion: 1\n---"

        expect(described_class.extract_target_name(body, field: 'target_repo')).to eq('my-gem')
      end
    end

    context 'when body is empty' do
      it 'returns nil' do
        expect(described_class.extract_target_name('', field: 'target_repo')).to be_nil
      end
    end

    context 'with only --- delimiters and no content' do
      it 'returns nil' do
        body = "---\n\n---"

        expect(described_class.extract_target_name(body, field: 'target_repo')).to be_nil
      end
    end

    context 'when front-matter value is numeric' do
      it 'coerces the value to a string' do
        body = "---\ntarget_repo: 123\n---"

        expect(described_class.extract_target_name(body, field: 'target_repo')).to eq('123')
      end
    end

    context 'when a different field name is specified' do
      it 'extracts that field instead' do
        body = "---\nrepo: other-gem\ntarget_repo: my-gem\n---"

        expect(described_class.extract_target_name(body, field: 'repo')).to eq('other-gem')
      end
    end
  end

  describe 'TargetResolutionError' do
    it 'is a subclass of StandardError' do
      expect(described_class::TargetResolutionError.superclass).to eq(StandardError)
    end
  end
end
