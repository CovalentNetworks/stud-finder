# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'
require 'stud_finder/coverage/lcov'

RSpec.describe StudFinder::Coverage::Lcov do
  def write_report(content)
    file = Tempfile.new(['coverage', '.info'])
    file.write(content)
    file.close
    file.path
  end

  def parse(content, files: %w[app/models/user.rb app/models/post.rb])
    path = write_report(content)
    described_class.new(path: path, files: files).call
  ensure
    FileUtils.rm_f(path) if path
  end

  it 'parses LF and LH fields as a fraction' do
    coverage = parse(<<~LCOV, files: ['app/models/user.rb'])
      TN:
      SF:app/models/user.rb
      LF:10
      LH:8
      end_of_record
    LCOV

    expect(coverage['app/models/user.rb']).to eq(0.8)
  end

  it 'falls back to DA line hits when summary fields are absent' do
    coverage = parse(<<~LCOV, files: ['app/models/user.rb'])
      SF:app/models/user.rb
      DA:1,1
      DA:2,0
      DA:3,4
      end_of_record
    LCOV

    expect(coverage['app/models/user.rb']).to eq(2.0 / 3.0)
  end

  it 'maps absent files to nil coverage' do
    coverage = parse(<<~LCOV)
      SF:app/models/user.rb
      LF:4
      LH:3
      end_of_record
    LCOV

    expect(coverage['app/models/user.rb']).to eq(0.75)
    expect(coverage['app/models/post.rb']).to be_nil
  end

  it 'raises a descriptive error when line coverage is missing' do
    path = write_report("SF:app/models/user.rb\nend_of_record\n")
    parser = described_class.new(path: path, files: ['app/models/user.rb'])

    expect { parser.call }.to raise_error(StudFinder::Coverage::Lcov::Error, /missing line coverage/)
  ensure
    FileUtils.rm_f(path) if path
  end
end
