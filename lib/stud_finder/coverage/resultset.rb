# frozen_string_literal: true

require 'json'

module StudFinder
  module Coverage
    class Resultset
      class Error < StandardError; end

      attr_reader :missing_files

      def initialize(path:, files:)
        @path = path
        @files = files
        @missing_files = []
      end

      def call
        reported = parse_report
        @missing_files = @files.reject { |file| reported.key?(file) }
        @files.to_h { |file| [file, reported.fetch(file, nil)] }
      end

      private

      def parse_report
        data = JSON.parse(File.read(@path))
        coverage_payloads(data).each_with_object({}) do |coverage, reported|
          coverage.each do |filename, details|
            lines = details.is_a?(Hash) ? details['lines'] : details
            next unless lines.is_a?(Array)

            reported[normalize_filename(filename)] = line_rate(lines, filename)
          end
        end
      rescue JSON::ParserError => e
        raise Error, "Error: malformed coverage JSON: #{e.message.lines.first.strip}"
      rescue Errno::ENOENT
        raise Error, "Error: coverage file not found: #{@path}"
      end

      def coverage_payloads(data)
        if data['coverage'].is_a?(Hash)
          [data['coverage']]
        else
          data.values.filter_map { |suite| suite['coverage'] if suite.is_a?(Hash) }
        end
      end

      def normalize_filename(filename)
        filename.delete_prefix('./')
      end

      def line_rate(lines, filename)
        executable = lines.compact
        raise Error, "Error: missing line coverage for coverage file: #{filename}" if executable.empty?

        executable.count(&:positive?).to_f / executable.length
      end
    end
  end
end
