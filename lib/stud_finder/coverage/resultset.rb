# frozen_string_literal: true

require 'json'

module StudFinder
  module Coverage
    class Resultset
      class Error < StandardError; end

      attr_reader :missing_files

      def initialize(path:, files:, repo_path: nil)
        @path = path
        @files = files
        @repo_path = repo_path
        @missing_files = []
      end

      def call
        reported = parse_report
        @missing_files = @files.reject { |file| reported.key?(file) }
        @files.to_h { |file| [file, reported.fetch(file, 0.0)] }
      end

      private

      def parse_report
        data = JSON.parse(File.read(@path))
        merged = {}

        coverage_payloads(data).each do |coverage|
          coverage.each do |filename, details|
            lines = details.is_a?(Hash) ? details['lines'] : details
            next unless lines.is_a?(Array)

            key = normalize_filename(filename)
            merged[key] = merged.key?(key) ? merge_lines(merged[key], lines) : lines
          end
        end

        merged.transform_values { |lines| line_rate(lines) }
      rescue JSON::ParserError => e
        raise Error, "Error: malformed coverage JSON: #{e.message.lines.first.strip}"
      rescue Errno::ENOENT
        raise Error, "Error: coverage file not found: #{@path}"
      end

      def merge_lines(previous_lines, new_lines)
        max_length = [previous_lines.length, new_lines.length].max

        (0...max_length).map do |index|
          previous = previous_lines[index]
          current = new_lines[index]

          previous.nil? && current.nil? ? nil : [previous || 0, current || 0].max
        end
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

      def line_rate(lines)
        executable = lines.compact
        return 0.0 if executable.empty?

        executable.count(&:positive?).to_f / executable.length
      end
    end
  end
end
