# frozen_string_literal: true

require 'json'
require 'spec_helper'
require 'stud_finder/complexity'

RSpec.describe StudFinder::Complexity do
  def status(exitstatus)
    instance_double(Process::Status, exitstatus: exitstatus)
  end

  def rubocop_json(files)
    JSON.generate('files' => files)
  end

  def run_complexity(stdout:, status: status(0), files: ['app/models/user.rb'], stderr: StringIO.new)
    allow(Open3).to receive(:capture3).and_return([stdout, '', status])

    described_class.new(repo_path: '/repo', files: files, stderr: stderr).call
  end

  it 'parses RuboCop JSON and sums per-method complexity per file' do
    stdout = rubocop_json([
                            {
                              'path' => '/repo/app/models/user.rb',
                              'offenses' => [
                                {
                                  'cop_name' => 'Metrics/CyclomaticComplexity',
                                  'message' => 'Cyclomatic complexity for create is too high. [8/7]'
                                },
                                {
                                  'cop_name' => 'Metrics/CyclomaticComplexity',
                                  'message' => 'Cyclomatic complexity for update is too high. [3/2]'
                                }
                              ]
                            }
                          ])

    result = run_complexity(stdout: stdout)

    expect(result.counts).to eq('app/models/user.rb' => 11)
  end

  it 'keeps files with no reported methods at zero' do
    result = run_complexity(stdout: rubocop_json([]), files: ['app/models/user.rb'])

    expect(result.counts).to eq('app/models/user.rb' => 0)
  end

  it 'treats exit codes 0 and 1 as parseable' do
    [0, 1].each do |exitstatus|
      result = run_complexity(stdout: rubocop_json([]), status: status(exitstatus))

      expect(result.counts).to eq('app/models/user.rb' => 0)
    end
  end

  it 'raises on RuboCop exit code 2' do
    allow(Open3).to receive(:capture3).and_return(['{}', 'fatal parse failure', status(2)])

    expect do
      described_class.new(repo_path: '/repo', files: ['app/models/user.rb']).call
    end.to raise_error(StudFinder::Complexity::Error, /rubocop failed: fatal parse failure/)
  end

  it 'skips per-file parse errors, logs to stderr, and continues' do
    stderr = StringIO.new
    stdout = rubocop_json([
                            {
                              'path' => '/repo/app/models/bad.rb',
                              'offenses' => [{ 'cop_name' => 'Lint/Syntax', 'message' => 'unexpected token' }]
                            },
                            {
                              'path' => '/repo/app/models/good.rb',
                              'offenses' => [
                                {
                                  'cop_name' => 'Metrics/CyclomaticComplexity',
                                  'message' => 'Cyclomatic complexity for call is too high. [5/3]'
                                }
                              ]
                            }
                          ])

    result = run_complexity(
      stdout: stdout,
      files: ['app/models/bad.rb', 'app/models/good.rb'],
      stderr: stderr
    )

    expect(result.counts).to eq('app/models/good.rb' => 5)
    expect(result.skipped_files).to eq(['app/models/bad.rb'])
    expect(stderr.string).to include('Warning: skipping app/models/bad.rb')
  end

  it 'uses --no-config in the RuboCop subprocess command' do
    run_complexity(stdout: rubocop_json([]))

    expect(Open3).to have_received(:capture3).with(
      'rubocop',
      '--no-config',
      '--only', 'Metrics/CyclomaticComplexity',
      '--format', 'json',
      '/repo'
    )
  end

  it 'raises the required message when rubocop is not in PATH' do
    allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

    expect do
      described_class.new(repo_path: '/repo', files: ['app/models/user.rb']).call
    end.to raise_error(StudFinder::Complexity::Error, 'Error: rubocop not found. Install it: gem install rubocop')
  end
end
