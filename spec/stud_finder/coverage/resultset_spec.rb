# frozen_string_literal: true

require 'json'
require 'spec_helper'
require 'tempfile'
require 'stud_finder/coverage/resultset'

RSpec.describe StudFinder::Coverage::Resultset do
  def write_report(payload)
    file = Tempfile.new(['resultset', '.json'])
    file.write(JSON.generate(payload))
    file.close
    file.path
  end

  def parse_resultset(payload, files: %w[app/models/user.rb app/models/post.rb])
    path = write_report(payload)
    described_class.new(path: path, files: files).call
  ensure
    FileUtils.rm_f(path) if path
  end

  it 'parses SimpleCov resultset coverage as a fraction' do
    coverage = parse_resultset(
      {
        'RSpec' => {
          'coverage' => {
            'app/models/user.rb' => { 'lines' => [nil, 1, 0, 3] }
          }
        }
      },
      files: ['app/models/user.rb']
    )

    expect(coverage['app/models/user.rb']).to eq(2.0 / 3.0)
  end

  it 'parses top-level coverage payloads' do
    coverage = parse_resultset(
      {
        'coverage' => {
          'app/models/user.rb' => [nil, 1, 1, 0]
        }
      },
      files: ['app/models/user.rb']
    )

    expect(coverage['app/models/user.rb']).to eq(2.0 / 3.0)
  end

  it 'maps files absent from the resultset to nil coverage' do
    coverage = parse_resultset(
      {
        'RSpec' => {
          'coverage' => {
            'app/models/user.rb' => { 'lines' => [1, 1] }
          }
        }
      }
    )

    expect(coverage['app/models/post.rb']).to be_nil
  end

  it 'raises a descriptive error for malformed JSON' do
    file = Tempfile.new(['resultset', '.json'])
    file.write('{')
    file.close
    parser = described_class.new(path: file.path, files: ['app/models/user.rb'])

    expect { parser.call }.to raise_error(StudFinder::Coverage::Resultset::Error, /malformed coverage JSON/)
  ensure
    file&.unlink
  end
end
