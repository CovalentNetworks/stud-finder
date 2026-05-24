# frozen_string_literal: true

require 'csv'
require 'spec_helper'
require 'stud_finder/cli'

RSpec.describe StudFinder::CLI do
  def run_cli(argv)
    stdout = StringIO.new
    stderr = StringIO.new
    status = described_class.new(argv, stdout: stdout, stderr: stderr).run
    [status, stdout.string, stderr.string]
  end

  def make_repo(file_count: 5)
    Dir.mktmpdir do |dir|
      system('git', 'init', '-q', dir)
      file_count.times do |i|
        path = File.join(dir, "app/models/model_#{i}.rb")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "class Model#{i}\nend\n")
      end
      yield dir
    end
  end

  def write_coverage_report(dir, files)
    path = File.join(dir, 'coverage.xml')
    classes = files.map do |file|
      %(<class filename="#{file}" line-rate="0.5" />)
    end.join("\n")
    File.write(path, <<~XML)
      <coverage><packages><package><classes>
      #{classes}
      </classes></package></packages></coverage>
    XML
    path
  end

  it 'prints help' do
    stdout = StringIO.new
    cli = described_class.new(['--help'], stdout: stdout, stderr: StringIO.new)

    expect { cli.run }.to raise_error(SystemExit) do |error|
      expect(error.status).to eq(0)
    end
    expect(stdout.string).to include('Usage: stud-finder [PATH] [OPTIONS]')
    expect(stdout.string).to include('--weights')
    expect(stdout.string).to include('--coverage')
  end

  it 'prints version' do
    stdout = StringIO.new
    cli = described_class.new(['--version'], stdout: stdout, stderr: StringIO.new)

    expect { cli.run }.to raise_error(SystemExit) do |error|
      expect(error.status).to eq(0)
    end
    expect(stdout.string).to include(StudFinder::VERSION)
  end

  it 'validates weights that do not sum to 1.0' do
    status, _stdout, stderr = run_cli(['--weights', 'fan_in:0.4,complexity:0.3,churn:0.1,coverage:0.0'])

    expect(status).to eq(1)
    expect(stderr).to include('actual sum is 0.8000')
  end

  it 'rejects coverage weight in Phase 1' do
    status, _stdout, stderr = run_cli(['--weights', 'fan_in:0.35,complexity:0.25,churn:0.25,coverage:0.15'])

    expect(status).to eq(1)
    expect(stderr).to include('coverage weight must be 0.0 in Phase 1')
  end

  it 'requires all weight keys' do
    status, _stdout, stderr = run_cli(['--weights', 'fan_in:0.5,complexity:0.3,churn:0.2'])

    expect(status).to eq(1)
    expect(stderr).to include('weights must include fan_in, complexity, churn, and coverage')
  end

  it 'reports a missing coverage file' do
    path = File.join(Dir.tmpdir, "stud-finder-coverage-nope-#{rand(100_000)}.xml")
    status, _stdout, stderr = run_cli(['--coverage', path])

    expect(status).to eq(1)
    expect(stderr).to include("Error: coverage file not found: #{path}")
  end

  it 'accepts a non-zero coverage weight when coverage is provided' do
    make_repo(file_count: 5) do |root|
      files = Array.new(5) { |i| "app/models/model_#{i}.rb" }
      coverage = write_coverage_report(root, files)
      allow_any_instance_of(StudFinder::Complexity).to receive(:call).and_return(
        StudFinder::Complexity::Result.new(counts: files.to_h { |file| [file, 0] }, skipped_files: [])
      )
      allow_any_instance_of(StudFinder::Churn).to receive(:call).and_return(
        StudFinder::Churn::Result.new(counts: files.to_h { |file| [file, 0] }, zero_inflated: false, zero_percentage: 0)
      )

      status, stdout, stderr = run_cli([
                                         root,
                                         '--min-files', '5',
                                         '--weights', 'fan_in:0.35,complexity:0.25,churn:0.25,coverage:0.15',
                                         '--coverage', coverage,
                                         '--output', 'json'
                                       ])

      expect(status).to eq(0)
      expect(stderr).not_to include('coverage weight must be 0.0')
      expect(JSON.parse(stdout).dig('meta', 'formula')).to eq('4-factor')
    end
  end

  it 'validates threshold ranges' do
    status, _stdout, stderr = run_cli(['--trunk-threshold', '100'])

    expect(status).to eq(1)
    expect(stderr).to include('trunk-threshold must be between 1 and 99')
  end

  it 'requires branch threshold to be less than trunk threshold' do
    status, _stdout, stderr = run_cli(['--trunk-threshold', '50', '--branch-threshold', '50'])

    expect(status).to eq(1)
    expect(stderr).to include('branch-threshold must be strictly less than trunk-threshold')
  end

  it 'returns path errors as exit 1 messages' do
    status, _stdout, stderr = run_cli([File.join(Dir.tmpdir, "stud-finder-nope-#{rand(100_000)}")])

    expect(status).to eq(1)
    expect(stderr).to include('does not exist')
  end

  it 'collects files and emits scored table output' do
    make_repo(file_count: 5) do |root|
      files = Array.new(5) { |i| "app/models/model_#{i}.rb" }
      allow_any_instance_of(StudFinder::Complexity).to receive(:call).and_return(
        StudFinder::Complexity::Result.new(counts: files.to_h { |file| [file, 0] }, skipped_files: [])
      )
      allow_any_instance_of(StudFinder::Churn).to receive(:call).and_return(
        StudFinder::Churn::Result.new(counts: files.to_h { |file| [file, 0] }, zero_inflated: false, zero_percentage: 0)
      )

      status, stdout, stderr = run_cli([root, '--min-files', '5'])

      expect(status).to eq(0)
      expect(stderr).to include('Score uses 3-factor formula')
      expect(stdout).to include('Note: JavaScript files not analyzed (Phase 1)')
      expect(stdout).to include('5 files analyzed')
      expect(stdout).to include('score')
      expect(stdout).to include('complexity')
      expect(stdout).to include('churn')
    end
  end

  it 'emits spreadsheet-ready csv output' do
    make_repo(file_count: 5) do |root|
      comma_path = File.join(root, 'app/models/model,with_comma.rb')
      FileUtils.rm_f(File.join(root, 'app/models/model_0.rb'))
      File.write(comma_path, "class ModelWithComma\nend\n")
      file = 'app/models/model,with_comma.rb'
      files = Array.new(4) { |i| "app/models/model_#{i + 1}.rb" } + [file]

      complexity_counts = files.to_h { |path| [path, path == file ? 7 : 0] }
      allow_any_instance_of(StudFinder::Complexity).to receive(:call).and_return(
        StudFinder::Complexity::Result.new(counts: complexity_counts, skipped_files: [])
      )
      allow_any_instance_of(StudFinder::Churn).to receive(:call).and_return(
        StudFinder::Churn::Result.new(
          counts: files.to_h { |path| [path, path == file ? 3 : 0] },
          zero_inflated: false,
          zero_percentage: 0
        )
      )

      status, stdout, stderr = run_cli([root, '--min-files', '5', '--top', '1', '--output', 'csv'])
      lines = stdout.lines
      rows = CSV.parse(stdout, nil_value: '')

      expect(status).to eq(0)
      expect(stderr).to include('Score uses 3-factor formula')
      expect(lines.length).to eq(2)
      expect(lines.first).to eq(
        "rank,file,score,class,fan_in,fan_in_pct,complexity,complexity_pct,churn,churn_pct,coverage\n"
      )
      expect(lines.last).to include('"app/models/model,with_comma.rb"')
      expect(rows.first).to eq(
        %w[rank file score class fan_in fan_in_pct complexity complexity_pct churn churn_pct coverage]
      )
      expect(rows.last).to eq(['1', file, '0.5882', 'leaf', '0', '0.0000', '7', '1.0000', '3', '1.0000', ''])
      expect(lines.last).to end_with(",\"\"\n")
    end
  end

  it 'surfaces too few file threshold failures' do
    make_repo(file_count: 4) do |root|
      status, _stdout, stderr = run_cli([root])

      expect(status).to eq(1)
      expect(stderr).to include('Too few for meaningful analysis')
    end
  end
  it 'rejects --coverage with a non-existent file' do
    missing = File.join(Dir.tmpdir, "stud-finder-coverage-nope-#{rand(100_000)}.xml")
    status, _stdout, stderr = run_cli(['--coverage', missing])

    expect(status).to eq(1)
    expect(stderr).to include("Error: coverage file not found: #{missing}")
  end

  it 'accepts positive coverage weight when --coverage is provided' do
    make_repo(file_count: 5) do |root|
      coverage_path = File.join(root, 'coverage.xml')
      files = Array.new(5) { |i| "app/models/model_#{i}.rb" }
      File.write(coverage_path, <<~XML)
        <coverage><packages><package><classes>
          #{files.map { |file| %(<class filename="#{file}" line-rate="0.5" />) }.join}
        </classes></package></packages></coverage>
      XML
      allow_any_instance_of(StudFinder::Complexity).to receive(:call).and_return(
        StudFinder::Complexity::Result.new(counts: files.to_h { |file| [file, 0] }, skipped_files: [])
      )
      allow_any_instance_of(StudFinder::Churn).to receive(:call).and_return(
        StudFinder::Churn::Result.new(counts: files.to_h { |file| [file, 0] }, zero_inflated: false, zero_percentage: 0)
      )

      status, _stdout, stderr = run_cli([
                                          root, '--min-files', '5', '--coverage', coverage_path,
                                          '--weights', 'fan_in:0.35,complexity:0.25,churn:0.25,coverage:0.15'
                                        ])

      expect(status).to eq(0), stderr
      expect(stderr).not_to include('coverage weight must be 0.0')
    end
  end
end
