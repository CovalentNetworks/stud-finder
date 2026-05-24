# frozen_string_literal: true

require_relative 'normalizer'

module StudFinder
  class Scorer
    DEFAULT_WEIGHTS = { fan_in: 0.35, complexity: 0.25, churn: 0.25, coverage: 0.15 }.freeze

    class ValidationError < StandardError; end

    attr_reader :normalized_weights

    # rubocop:disable Metrics/ParameterLists
    def initialize(files:, fan_in:, complexity:, churn:, weights: DEFAULT_WEIGHTS, branch_threshold: 50,
                   trunk_threshold: 85)
      @files = files
      @fan_in = fan_in
      @complexity = complexity
      @churn = churn
      @weights = weights
      @branch_threshold = branch_threshold
      @trunk_threshold = trunk_threshold
      validate!
      @normalized_weights = normalize_weights
    end
    # rubocop:enable Metrics/ParameterLists

    def call
      fan_in_pct = Normalizer.percentile_rank(@fan_in, @files)
      complexity_pct = Normalizer.percentile_rank(@complexity, @files)
      churn_pct = Normalizer.percentile_rank(@churn, @files)

      rows = @files.each_with_index.map do |file, index|
        score = weighted_score(file, fan_in_pct, complexity_pct, churn_pct)
        [index, result_row(file, score, fan_in_pct, complexity_pct, churn_pct)]
      end

      rows.sort_by { |index, row| [-row[:score], index] }
          .map.with_index(1) do |(_index, row), rank|
        row.merge(rank: rank)
      end
    end

    private

    def validate!
      return if @branch_threshold < @trunk_threshold

      raise ValidationError, 'Error: branch-threshold must be strictly less than trunk-threshold.'
    end

    def normalize_weights
      active_total = @weights.fetch(:fan_in, 0.0) + @weights.fetch(:complexity, 0.0) + @weights.fetch(:churn, 0.0)
      raise ValidationError, 'Error: active weights must be greater than 0.0.' if active_total <= 0.0

      {
        fan_in: @weights.fetch(:fan_in, 0.0) / active_total,
        complexity: @weights.fetch(:complexity, 0.0) / active_total,
        churn: @weights.fetch(:churn, 0.0) / active_total,
        coverage: nil
      }
    end

    def weighted_score(file, fan_in_pct, complexity_pct, churn_pct)
      (@normalized_weights[:fan_in] * fan_in_pct.fetch(file)) +
        (@normalized_weights[:complexity] * complexity_pct.fetch(file)) +
        (@normalized_weights[:churn] * churn_pct.fetch(file))
    end

    def result_row(file, score, fan_in_pct, complexity_pct, churn_pct)
      {
        path: file,
        score: score.round(4),
        classification: classification(fan_in_pct.fetch(file)),
        fan_in: @fan_in.fetch(file, 0).to_i,
        fan_in_pct: fan_in_pct.fetch(file).round(4),
        complexity: @complexity.fetch(file, 0).to_i,
        complexity_pct: complexity_pct.fetch(file).round(4),
        churn: @churn.fetch(file, 0).to_i,
        churn_pct: churn_pct.fetch(file).round(4),
        coverage: nil
      }
    end

    def classification(fan_in_pct)
      return 'trunk' if fan_in_pct >= @trunk_threshold / 100.0
      return 'branch' if fan_in_pct >= @branch_threshold / 100.0

      'leaf'
    end
  end
end
