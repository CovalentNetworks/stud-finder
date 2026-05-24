# frozen_string_literal: true

require 'spec_helper'
require 'stud_finder/churn'

RSpec.describe StudFinder::Churn do
  def status(success)
    instance_double(Process::Status, success?: success)
  end

  def run_churn(stdout:, status: status(true), files: ['app/models/user.rb'], days: 90, stderr: StringIO.new)
    allow(Open3).to receive(:capture3).and_return([stdout, '', status])

    described_class.new(repo_path: '/repo', files: files, days: days, stderr: stderr).call
  end

  it 'parses NUL-delimited git output and keeps zeroes for files not appearing' do
    result = run_churn(
      stdout: "app/models/user.rb\0app/models/user.rb\0app/models/file with spaces.rb\0",
      files: ['app/models/user.rb', 'app/models/file with spaces.rb', 'app/models/order.rb']
    )

    expect(result.counts).to eq(
      'app/models/user.rb' => 2,
      'app/models/file with spaces.rb' => 1,
      'app/models/order.rb' => 0
    )
  end

  it 'uses rename-safe git log flags' do
    run_churn(stdout: '')

    expect(Open3).to have_received(:capture3).with(
      'git', '-C', '/repo', 'log',
      '--since=90 days ago',
      '--format=tformat:',
      '-z',
      '--diff-filter=ACDMR',
      '--name-only'
    )
  end

  it 'detects zero-inflated churn and warns' do
    stderr = StringIO.new

    result = run_churn(
      stdout: "app/models/a.rb\0",
      files: ['app/models/a.rb', 'app/models/b.rb', 'app/models/c.rb'],
      days: 7,
      stderr: stderr
    )

    expect(result.zero_inflated).to be(true)
    expect(result.zero_percentage).to eq(67)
    expect(stderr.string).to include('Warning: 67% of files have zero churn in the last 7 days')
  end

  it 'raises a clear message when git is not in PATH' do
    allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

    expect do
      described_class.new(repo_path: '/repo', files: ['app/models/user.rb'], days: 90).call
    end.to raise_error(StudFinder::Churn::Error, 'Error: git not found in PATH.')
  end

  it 'raises a clear message when the path is not a git repository' do
    expect do
      run_churn(stdout: '', status: status(false))
    end.to raise_error(StudFinder::Churn::Error, 'Error: /repo is not a git repository.')
  end
end
