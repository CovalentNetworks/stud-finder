# frozen_string_literal: true

require 'spec_helper'
require 'stud_finder/scorer'

RSpec.describe StudFinder::Scorer do
  let(:files) { %w[a.rb b.rb c.rb d.rb] }
  let(:fan_in) { { 'a.rb' => 3, 'b.rb' => 2, 'c.rb' => 1, 'd.rb' => 0 } }
  let(:complexity) { { 'a.rb' => 1, 'b.rb' => 10, 'c.rb' => 0, 'd.rb' => 0 } }
  let(:churn) { { 'a.rb' => 0, 'b.rb' => 1, 'c.rb' => 10, 'd.rb' => 0 } }

  def scorer(**overrides)
    options = {
      files: files,
      fan_in: fan_in,
      complexity: complexity,
      churn: churn,
      weights: { fan_in: 0.35, complexity: 0.25, churn: 0.25, coverage: 0.0 },
      branch_threshold: 50,
      trunk_threshold: 85
    }.merge(overrides)

    described_class.new(**options)
  end

  it 'renormalizes Phase 1 active weights to sum to 1.0' do
    weights = scorer.normalized_weights

    expect(weights[:fan_in]).to be_within(0.0001).of(0.4118)
    expect(weights[:complexity]).to be_within(0.0001).of(0.2941)
    expect(weights[:churn]).to be_within(0.0001).of(0.2941)
    expect(weights[:coverage]).to be_nil
    expect(weights.values.compact.sum).to be_within(0.0001).of(1.0)
  end

  it 'produces scores in the inclusive 0.0 to 1.0 range' do
    scores = scorer.call.map { |row| row[:score] }

    expect(scores).to all(be_between(0.0, 1.0).inclusive)
  end

  it 'classifies by fan_in percentile only' do
    rows = scorer.call.to_h { |row| [row[:path], row] }

    expect(rows['a.rb'][:classification]).to eq('trunk')
    expect(rows['b.rb'][:classification]).to eq('branch')
    expect(rows['c.rb'][:classification]).to eq('leaf')
  end

  it 'raises when branch threshold is not less than trunk threshold' do
    expect { scorer(branch_threshold: 85, trunk_threshold: 85) }
      .to raise_error(StudFinder::Scorer::ValidationError, /branch-threshold/)
  end

  it 'sorts rows by score descending' do
    scores = scorer.call.map { |row| row[:score] }

    expect(scores).to eq(scores.sort.reverse)
  end
end
