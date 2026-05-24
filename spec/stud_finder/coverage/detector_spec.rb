# frozen_string_literal: true

require 'spec_helper'
require 'stud_finder/coverage/cobertura'
require 'stud_finder/coverage/detector'
require 'stud_finder/coverage/lcov'
require 'stud_finder/coverage/resultset'

RSpec.describe StudFinder::Coverage::Detector do
  it 'detects Cobertura XML reports' do
    parser = described_class.for(path: 'coverage.xml', files: [])

    expect(parser).to be_a(StudFinder::Coverage::Cobertura)
  end

  it 'detects LCOV info reports' do
    parser = described_class.for(path: 'lcov.info', files: [])

    expect(parser).to be_a(StudFinder::Coverage::Lcov)
  end

  it 'detects SimpleCov resultset JSON reports' do
    parser = described_class.for(path: 'resultset.json', files: [])

    expect(parser).to be_a(StudFinder::Coverage::Resultset)
  end

  it 'rejects unsupported coverage file types' do
    expect { described_class.for(path: 'coverage.txt', files: []) }
      .to raise_error(StudFinder::Coverage::Detector::Error, /unsupported coverage file type/)
  end
end
