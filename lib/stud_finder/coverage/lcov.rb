# frozen_string_literal: true

module StudFinder
  module Coverage
    class Lcov
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
        records = File.read(@path).split(/^end_of_record\s*$/)
        records.each_with_object({}) do |record, coverage|
          filename = record[/^SF:(.+)$/, 1]
          next if filename.nil? || filename.empty?

          coverage[normalize_filename(filename)] = line_rate(record, filename)
        end
      rescue Errno::ENOENT
        raise Error, "Error: coverage file not found: #{@path}"
      end

      def normalize_filename(filename)
        filename.delete_prefix('./')
      end

      def line_rate(record, filename)
        found = integer_field(record, 'LF')
        hit = integer_field(record, 'LH')

        if found.nil? || hit.nil?
          lines = record.scan(/^DA:\d+,(\d+)/).flatten.map(&:to_i)
          found = lines.length
          hit = lines.count(&:positive?)
        end

        return 0.0 if found.zero?
        raise Error, "Error: line hits exceed lines found for coverage file: #{filename}" if hit > found

        hit.to_f / found
      end

      def integer_field(record, field)
        raw = record[/^#{field}:(\d+)$/, 1]
        raw&.to_i
      end
    end
  end
end
