# frozen_string_literal: true

require 'json'
require 'open3'

module StudFinder
  class Complexity
    Result = Struct.new(:counts, :skipped_files, keyword_init: true)

    class Error < StandardError; end

    COMPLEXITY_COP = 'Metrics/CyclomaticComplexity'
    COMPLEXITY_PATTERN = %r{\[(\d+)/\d+\]}
    PARSE_ERROR_COPS = %w[Lint/Syntax].freeze

    def initialize(repo_path:, files:, stderr: $stderr)
      @repo_path = File.expand_path(repo_path)
      @files = files
      @stderr = stderr
    end

    def call
      stdout, stderr, status = run_rubocop
      raise Error, fatal_message(stderr) if status.exitstatus == 2
      raise Error, fatal_message(stderr) unless [0, 1].include?(status.exitstatus)

      parse(stdout)
    rescue Errno::ENOENT
      raise Error, 'Error: rubocop not found. Install it: gem install rubocop'
    rescue JSON::ParserError => e
      raise Error, "Error: failed to parse RuboCop JSON output: #{e.message}"
    end

    private

    def run_rubocop
      stdout, stderr, status = Open3.capture3(
        'rubocop',
        '--no-config',
        '--only', COMPLEXITY_COP,
        '--format', 'json',
        @repo_path
      )
      return [stdout, stderr, status] unless unsupported_no_config?(stderr, status)

      Open3.capture3(
        'rubocop',
        '--force-default-config',
        '--only', COMPLEXITY_COP,
        '--format', 'json',
        @repo_path
      )
    end

    def unsupported_no_config?(stderr, status)
      status.exitstatus == 2 && stderr.include?('invalid option: --no-config')
    end

    def parse(stdout)
      payload = JSON.parse(stdout)
      counts = @files.to_h { |file| [file, 0] }
      skipped = []
      file_set = counts.keys.to_h { |file| [file, true] }

      Array(payload['files']).each do |entry|
        relative = normalize_path(entry['path'].to_s)
        next unless file_set[relative]

        offenses = Array(entry['offenses'])
        if parse_error?(offenses)
          skipped << relative
          counts.delete(relative)
          @stderr.puts "Warning: skipping #{relative}; RuboCop could not parse file."
          next
        end

        counts[relative] = offenses.sum { |offense| complexity_score(offense) }
      end

      Result.new(counts: counts, skipped_files: skipped)
    end

    def complexity_score(offense)
      return 0 unless offense['cop_name'] == COMPLEXITY_COP

      offense.fetch('message', '').match(COMPLEXITY_PATTERN)&.[](1).to_i
    end

    def parse_error?(offenses)
      offenses.any? { |offense| PARSE_ERROR_COPS.include?(offense['cop_name']) || offense['fatal'] == true }
    end

    def normalize_path(path)
      absolute = File.expand_path(path, @repo_path)
      absolute.start_with?("#{@repo_path}/") ? absolute.delete_prefix("#{@repo_path}/") : path
    end

    def fatal_message(stderr)
      message = stderr.to_s.strip
      return 'Error: rubocop failed.' if message.empty?

      "Error: rubocop failed: #{message}"
    end
  end
end
