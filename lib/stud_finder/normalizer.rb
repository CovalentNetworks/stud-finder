# frozen_string_literal: true

module StudFinder
  module Normalizer
    module_function

    def percentile_rank(raw_counts, files)
      return {} if files.empty?

      values = files.map { |file| raw_counts.fetch(file, 0).to_f }
      return files.to_h { |file| [file, 0.0] } if files.length == 1 || values.uniq.length == 1

      denominator = files.length - 1
      sorted_values = values.sort

      files.to_h do |file|
        raw = raw_counts.fetch(file, 0).to_f
        [file, lower_bound(sorted_values, raw).to_f / denominator]
      end
    end

    def lower_bound(sorted_values, raw)
      low = 0
      high = sorted_values.length

      while low < high
        mid = (low + high) / 2
        if sorted_values[mid] < raw
          low = mid + 1
        else
          high = mid
        end
      end

      low
    end
  end
end
