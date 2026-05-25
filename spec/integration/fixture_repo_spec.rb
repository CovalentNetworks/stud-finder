# frozen_string_literal: true

require 'json'
require 'open3'
require 'spec_helper'

RSpec.describe 'fixture repo integration' do
  let(:source_fixture) { File.expand_path('../fixtures/sample_app', __dir__) }
  let(:repo_path) { Dir.mktmpdir('stud-finder-sample-app') }
  let(:bin_path) { File.expand_path('../../bin/stud-finder', __dir__) }

  before do
    FileUtils.cp_r(Dir.glob(File.join(source_fixture, '*')), repo_path)
    initialize_git_repo
  end

  after do
    FileUtils.remove_entry(repo_path)
  end

  it 'ranks the sample app and emits valid table output' do
    stdout, stderr, status = run_cli('--min-files', '5')

    expect(status).to be_success, stderr
    expect(stdout).to include('rank')
    expect(stdout).to include('score')
    expect(stdout).to include('class')
    expect(stdout).to include('JavaScript/TypeScript')
    expect(top_table_row(stdout)).to include('app/models/user.rb')
    expect(top_table_score(stdout)).to be > 0.0
  end

  it 'emits normative JSON output with ranked scores' do
    stdout, stderr, status = run_cli('--min-files', '5', '--output', 'json')
    payload = JSON.parse(stdout)

    expect(status).to be_success, stderr
    expect(payload.keys).to contain_exactly('meta', 'warnings', 'ruby', 'javascript')
    expect(payload['meta'].keys).to include('repo', 'analyzed_at', 'churn_days', 'file_count', 'files_skipped',
                                            'formula', 'weights', 'warnings')
    expect(payload['warnings']).to include('coverage_unavailable')
    expect(payload['meta']['warnings']).to eq(payload['warnings'])
    expect(payload['javascript']).to eq([])

    files = payload.fetch('ruby')
    expect(files.first['path']).to eq('app/models/user.rb')
    expect(files.first['score']).to be > 0.0
    expect(files.map { |file| file['score'] }).to all(be_between(0.0, 1.0).inclusive)
    expect(files.map { |file| file['score'] }).to eq(files.map { |file| file['score'] }.sort.reverse)
    expect(files.first.keys).to include('rank', 'path', 'score', 'class', 'fan_in', 'fan_in_pct', 'complexity',
                                        'complexity_pct', 'churn_commits', 'churn_lines', 'churn_pct', 'coverage')
  end

  it 'emits JSON output with Cobertura coverage integrated' do
    coverage_path = File.join(repo_path, 'coverage/coverage.xml')
    stdout, stderr, status = run_cli('--min-files', '5', '--output', 'json', '--ruby-coverage', coverage_path)
    payload = JSON.parse(stdout)

    expect(status).to be_success, stderr
    files = payload['ruby'].to_h { |file| [file['path'], file] }
    expect(files['app/models/user.rb']['coverage']).to eq(1.0)
    expect(files['app/services/auth_service.rb']['coverage']).to eq(0.0)
    expect(files['app/services/auth_service.rb']['score']).to be > files['app/services/post_service.rb']['score']
  end

  it 'scores files absent from a partial Cobertura report with the four-factor formula' do
    coverage_path = File.join(repo_path, 'coverage/coverage.xml')
    coverage_xml = File.read(coverage_path)
    File.write(coverage_path, coverage_xml.sub(%r{\s*<class filename="app/models/post\.rb" line-rate="0\.95" />}, ''))

    stdout, stderr, status = run_cli('--min-files', '5', '--output', 'json', '--ruby-coverage', coverage_path)
    payload = JSON.parse(stdout)

    expect(status).to be_success, stderr
    files = payload['ruby'].to_h { |file| [file['path'], file] }
    expect(files['app/models/post.rb']['coverage']).to eq(0.0)
    expect(files['app/models/post.rb']['score']).to be_within(0.0001).of(0.4611)
    expect(files['app/models/profile.rb']['coverage']).to eq(0.75)
    expect(files['app/models/profile.rb']['score']).to be_within(0.0001).of(0.3097)
  end

  it 'emits markdown output' do
    stdout, stderr, status = run_cli('--min-files', '5', '--output', 'markdown')

    expect(status).to be_success, stderr
    expect(stdout).to include(
      '| rank | file | score | class | fan_in | complexity | churn_commits | churn_lines | churn_pct | coverage |'
    )
    expect(stdout).to include('| 1 | app/models/user.rb |')
  end

  def run_cli(*args)
    Open3.capture3('bundle', 'exec', 'ruby', bin_path, repo_path, *args)
  end

  def initialize_git_repo
    system('git', 'init', '-q', repo_path)
    system('git', '-C', repo_path, 'config', 'user.email', 'stud-finder@example.test')
    system('git', '-C', repo_path, 'config', 'user.name', 'Stud Finder')
    system('git', '-C', repo_path, 'add', '.')
    system('git', '-C', repo_path, 'commit', '-qm', 'initial sample app')
    File.open(File.join(repo_path, 'app/models/user.rb'), 'a') { |file| file.puts "\n# churn marker" }
    system('git', '-C', repo_path, 'add', 'app/models/user.rb')
    system('git', '-C', repo_path, 'commit', '-qm', 'touch user model')
    File.open(File.join(repo_path, 'app/models/user.rb'), 'a') { |file| file.puts '# another churn marker' }
    system('git', '-C', repo_path, 'add', 'app/models/user.rb')
    system('git', '-C', repo_path, 'commit', '-qm', 'touch user model again')
  end

  def top_table_row(stdout)
    stdout.lines.find { |line| line.match?(/^\s*1\s+/) }
  end

  def top_table_score(stdout)
    top_table_row(stdout).split[2].to_f
  end
end
