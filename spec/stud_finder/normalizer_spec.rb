# frozen_string_literal: true

require 'spec_helper'
require 'stud_finder/normalizer'

RSpec.describe StudFinder::Normalizer do
  describe '.percentile_rank' do
    it 'uses the lower-bound percentile formula' do
      files = %w[a.rb b.rb c.rb d.rb e.rb]
      counts = files.each_with_index.to_h

      result = described_class.percentile_rank(counts, files)

      expect(result['c.rb']).to eq(0.5)
    end

    it 'gives ties the same lower-bound rank' do
      files = %w[a.rb b.rb c.rb d.rb]
      counts = { 'a.rb' => 0, 'b.rb' => 1, 'c.rb' => 1, 'd.rb' => 2 }

      result = described_class.percentile_rank(counts, files)

      expect(result['b.rb']).to be_within(0.001).of(1.0 / 3)
      expect(result['c.rb']).to be_within(0.001).of(1.0 / 3)
    end

    it 'returns 0.0 for a single file' do
      expect(described_class.percentile_rank({ 'a.rb' => 10 }, ['a.rb'])).to eq('a.rb' => 0.0)
    end

    it 'returns 0.0 when all values are the same' do
      files = %w[a.rb b.rb c.rb]

      expect(described_class.percentile_rank(files.to_h { |file| [file, 5] }, files).values).to all(eq(0.0))
    end

    it 'returns 0.0 when all values are zero' do
      files = %w[a.rb b.rb c.rb d.rb]

      expect(described_class.percentile_rank({}, files).values).to all(eq(0.0))
    end
  end
end
