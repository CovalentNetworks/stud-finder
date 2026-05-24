# frozen_string_literal: true

require_relative 'cobertura'
require_relative 'lcov'
require_relative 'resultset'

module StudFinder
  module Coverage
    class Detector
      class Error < StandardError; end

      PARSERS = {
        '.xml' => Cobertura,
        '.info' => Lcov,
        '.json' => Resultset
      }.freeze

      def self.for(path:, files:)
        parser = PARSERS[File.extname(path).downcase]
        raise Error, "Error: unsupported coverage file type: #{path}" if parser.nil?

        parser.new(path: path, files: files)
      end
    end
  end
end
