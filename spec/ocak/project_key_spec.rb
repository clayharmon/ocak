# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Ocak::ProjectKey do
  describe '.resolve' do
    def stub_remote(url, success: true)
      status = instance_double(Process::Status, success?: success)
      allow(Open3).to receive(:capture3)
        .with('git', 'remote', 'get-url', 'origin', chdir: anything)
        .and_return([url, '', status])
    end

    it 'parses SSH URL' do
      stub_remote("git@github.com:clayharmon/ocak.git\n")
      expect(described_class.resolve('/tmp')).to eq('clayharmon/ocak')
    end

    it 'parses HTTPS URL with .git' do
      stub_remote("https://github.com/clayharmon/ocak.git\n")
      expect(described_class.resolve('/tmp')).to eq('clayharmon/ocak')
    end

    it 'parses HTTPS URL without .git' do
      stub_remote("https://github.com/owner/repo\n")
      expect(described_class.resolve('/tmp')).to eq('owner/repo')
    end

    it 'works with non-GitHub hosts' do
      stub_remote("git@gitlab.com:org/project.git\n")
      expect(described_class.resolve('/tmp')).to eq('org/project')
    end

    it 'raises NoRemoteError when git command fails' do
      stub_remote('', success: false)
      expect { described_class.resolve('/tmp') }.to raise_error(described_class::NoRemoteError)
    end

    it 'raises NoRemoteError for unparseable URL' do
      stub_remote("not-a-valid-url\n")
      expect { described_class.resolve('/tmp') }.to raise_error(described_class::NoRemoteError)
    end

    it 'defaults dir to Dir.pwd' do
      stub_remote("git@github.com:a/b.git\n")
      allow(Dir).to receive(:pwd).and_return('/tmp')
      expect(described_class.resolve).to eq('a/b')
    end
  end
end
