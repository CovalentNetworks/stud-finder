# frozen_string_literal: true

require 'json'
require 'optparse'
require_relative 'file_collector'
require_relative 'version'

module StudFinder
  class CLI
    OUTPUT_FORMATS = %w[table json markdown].freeze
    WEIGHT_KEYS = %i[fan_in complexity churn coverage].freeze
    DEFAULT_OPTIONS = {
      output: 'table',
      churn_days: 90,
      weights: { fan_in: 0.35, complexity: 0.25, churn: 0.25, coverage: 0.15 },
      custom_weights: false,
      trunk_threshold: 85,
      branch_threshold: 50,
      excludes: [],
      min_files: 20,
      top: nil,
      verbose: false
    }.freeze

    class ValidationError < StandardError; end

    def initialize(argv, stdout: $stdout, stderr: $stderr)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @options = Marshal.load(Marshal.dump(DEFAULT_OPTIONS))
    end

    def self.start(argv = ARGV, stdout: $stdout, stderr: $stderr)
      new(argv, stdout: stdout, stderr: stderr).run
    end

    def run
      parser = option_parser
      parser.parse!(@argv)
      path = @argv.shift || '.'
      raise ValidationError, "Error: unexpected arguments: #{@argv.join(' ')}" unless @argv.empty?

      validate_options!

      result = FileCollector.new(
        path: path,
        excludes: @options[:excludes],
        min_files: @options[:min_files],
        stderr: @stderr
      ).collect

      emit_placeholder(File.expand_path(path), result)
      0
    rescue OptionParser::InvalidOption, OptionParser::MissingArgument, OptionParser::InvalidArgument, ValidationError,
           FileCollector::Error => e
      @stderr.puts e.message
      1
    end

    private

    def option_parser
      OptionParser.new do |opts|
        opts.banner = 'Usage: stud-finder [PATH] [OPTIONS]'
        opts.separator ''
        opts.separator 'Options:'

        opts.on('--output FORMAT', OUTPUT_FORMATS, 'Output format: table, json, markdown (default: table)') do |value|
          @options[:output] = value
        end
        opts.on('--churn-days N', Integer, 'Commit lookback window in days (default: 90)') do |value|
          @options[:churn_days] = value
        end
        opts.on('--weights WEIGHTS', 'fan_in:F,complexity:C,churn:H,coverage:V') do |value|
          @options[:weights] = parse_weights(value)
          @options[:custom_weights] = true
        end
        opts.on('--trunk-threshold N', Integer,
                'fan_in percentile cutoff for trunk classification (default: 85)') do |value|
          @options[:trunk_threshold] = value
        end
        opts.on('--branch-threshold N', Integer,
                'fan_in percentile cutoff for branch classification (default: 50)') do |value|
          @options[:branch_threshold] = value
        end
        opts.on('--exclude PATTERN', 'Exclude glob pattern (repeatable)') do |value|
          @options[:excludes] << value
        end
        opts.on('--min-files N', Integer, 'Advisory minimum file count (default: 20)') do |value|
          @options[:min_files] = value
        end
        opts.on('--top N', Integer, 'Emit only the top N results') do |value|
          @options[:top] = value
        end
        opts.on('--verbose', 'Print suppressed per-file warnings to stderr') do
          @options[:verbose] = true
        end
        opts.on('--version', 'Print version and exit') do
          @stdout.puts StudFinder::VERSION
          exit 0
        end
        opts.on('--help', 'Print help and exit') do
          @stdout.puts opts
          exit 0
        end
      end
    end

    def parse_weights(value)
      pairs = value.split(',').map do |entry|
        key, raw = entry.split(':', 2)
        raise ValidationError, 'Error: invalid weights format.' if key.nil? || raw.nil? || key.empty? || raw.empty?

        [key.to_sym, Float(raw)]
      rescue ArgumentError
        raise ValidationError, 'Error: weight values must be floats.'
      end

      weights = pairs.to_h
      missing = WEIGHT_KEYS - weights.keys
      extra = weights.keys - WEIGHT_KEYS
      unless missing.empty? && extra.empty?
        raise ValidationError,
              'Error: weights must include fan_in, complexity, churn, and coverage.'
      end

      out_of_range = weights.any? { |_key, weight| weight.negative? || weight > 1.0 }
      raise ValidationError, 'Error: weight values must be between 0.0 and 1.0.' if out_of_range

      weights
    end

    def validate_options!
      validate_threshold!(:trunk_threshold)
      validate_threshold!(:branch_threshold)
      if @options[:branch_threshold] >= @options[:trunk_threshold]
        raise ValidationError, 'Error: branch-threshold must be strictly less than trunk-threshold.'
      end

      raise ValidationError, 'Error: --min-files must be positive.' if @options[:min_files] <= 0
      raise ValidationError, 'Error: --top must be positive.' if @options[:top] && @options[:top] <= 0
      raise ValidationError, 'Error: --churn-days must be positive.' if @options[:churn_days] <= 0

      validate_weights! if @options[:custom_weights]
    end

    def validate_threshold!(name)
      value = @options[name]
      return if value.between?(1, 99)

      raise ValidationError, "Error: #{name.to_s.tr('_', '-')} must be between 1 and 99."
    end

    def validate_weights!
      weights = @options[:weights]
      if weights[:coverage].positive?
        raise ValidationError, 'Error: coverage weight must be 0.0 in Phase 1 (no coverage data available).'
      end

      active_sum = weights.values.sum
      return if (active_sum - 1.0).abs <= 0.001

      raise ValidationError, format('Error: weights must sum to 1.0; actual sum is %.4f.', active_sum)
    end

    def emit_placeholder(path, result)
      case @options[:output]
      when 'json'
        @stdout.puts JSON.generate(
          meta: {
            repo: path,
            churn_days: @options[:churn_days],
            file_count: result.files.length,
            warnings: %w[coverage_unavailable js_not_analyzed],
            status: 'scoring not yet implemented'
          },
          files: []
        )
      when 'markdown'
        @stdout.puts "## stud-finder — #{File.basename(path)}"
        @stdout.puts
        @stdout.puts '> JavaScript files not analyzed (Phase 1).'
        @stdout.puts "> #{result.files.length} Ruby files collected."
        @stdout.puts
        @stdout.puts 'scoring not yet implemented'
      else
        @stdout.puts "stud-finder — #{path} (#{@options[:churn_days]}-day churn, 3-factor score)"
        @stdout.puts 'Note: JavaScript files not analyzed (Phase 1). Cross-language dependencies not tracked.'
        @stdout.puts "#{result.files.length} Ruby files collected."
        @stdout.puts 'scoring not yet implemented'
      end
    end
  end
end
