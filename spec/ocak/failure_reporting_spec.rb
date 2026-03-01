# frozen_string_literal: true

require 'spec_helper'
require 'ocak/failure_reporting'

RSpec.describe Ocak::FailureReporting do
  let(:includer) { Class.new { include Ocak::FailureReporting }.new }
  let(:issues) { instance_double(Ocak::IssueFetcher) }
  let(:config) do
    instance_double(Ocak::Config,
                    label_in_progress: 'in-progress',
                    label_failed: 'pipeline-failed')
  end

  before do
    allow(issues).to receive(:transition)
    allow(issues).to receive(:comment)
  end

  it 'transitions label from in-progress to failed' do
    result = { phase: 'implement', output: 'some error' }

    includer.report_pipeline_failure(42, result, issues: issues, config: config)

    expect(issues).to have_received(:transition).with(42, from: 'in-progress', to: 'pipeline-failed')
  end

  it 'posts a comment with phase and truncated output' do
    result = { phase: 'review', output: 'failure details' }

    includer.report_pipeline_failure(42, result, issues: issues, config: config)

    expect(issues).to have_received(:comment).with(
      42, "Pipeline failed at phase: review\n\n```\nfailure details\n```"
    )
  end

  it 'truncates output to 1000 characters' do
    long_output = 'x' * 2000
    result = { phase: 'implement', output: long_output }

    includer.report_pipeline_failure(7, result, issues: issues, config: config)

    expect(issues).to have_received(:comment) do |_issue, body|
      # output[0..1000] yields 1001 chars
      code_block_content = body[/```\n(.*)\n```/m, 1]
      expect(code_block_content.length).to eq(1001)
    end
  end

  it 'does not raise when comment fails' do
    allow(issues).to receive(:comment).and_raise(StandardError, 'GitHub API down')
    result = { phase: 'implement', output: 'error' }

    expect { includer.report_pipeline_failure(42, result, issues: issues, config: config) }.not_to raise_error
  end
end
