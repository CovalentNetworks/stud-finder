# frozen_string_literal: true

require 'open3'
require 'pathname'

module StudFinder
  class FileCollector
    DEFAULT_EXCLUDES = [
      'db/schema.rb',
      'db/migrate/**',
      '**/node_modules/**',
      'vendor/**',
      '**/*.min.js',
      'tmp/**',
      'log/**'
    ].freeze

    FNM_FLAGS = File::FNM_PATHNAME | File::FNM_DOTMATCH

    Result = Struct.new(:files, :default_excluded_count, :custom_excluded_count, keyword_init: true)

    class Error < StandardError; end

    def initialize(path:, excludes: [], min_files: 20, stderr: $stderr)
      @path = File.expand_path(path)
      @excludes = excludes
      @min_files = min_files
      @stderr = stderr
    end

    def collect
      validate!

      default_excluded = 0
      custom_excluded = 0
      files = Dir.glob(File.join(@path, '**', '*.rb'), File::FNM_DOTMATCH)
                 .select { |file| File.file?(file) }
                 .sort
                 .filter_map do |file|
        relative = relative_path(file)

        if default_excluded?(relative, file)
          default_excluded += 1
          next
        end

        if excluded_by_patterns?(relative, @excludes)
          custom_excluded += 1
          next
        end

        relative
      end

      if files.length < 5
        raise Error, "Error: only #{files.length} .rb files found after excludes. Too few for meaningful analysis."
      end

      if files.length < @min_files
        @stderr.puts "Warning: only #{files.length} files found. Percentile ranks are unreliable at this scale. " \
                     'Results are advisory only.'
      end

      Result.new(files: files, default_excluded_count: default_excluded, custom_excluded_count: custom_excluded)
    end

    private

    def validate!
      raise Error, "Error: #{@path} does not exist." unless File.exist?(@path)
      raise Error, "Error: #{@path} is not a directory." unless File.directory?(@path)
      raise Error, 'Error: git not found in PATH.' unless git_available?

      _stdout, _stderr, status = Open3.capture3('git', '-C', @path, 'rev-parse', '--is-inside-work-tree')
      return if status.success?

      raise Error, "Error: #{@path} is not a git repository."
    end

    def git_available?
      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |dir|
        git = File.join(dir, 'git')
        File.file?(git) && File.executable?(git)
      end
    end

    def relative_path(file)
      Pathname.new(file).relative_path_from(Pathname.new(@path)).to_s
    end

    def default_excluded?(relative, file)
      excluded_by_patterns?(relative, DEFAULT_EXCLUDES) || auto_generated?(file)
    end

    def excluded_by_patterns?(relative, patterns)
      patterns.any? { |pattern| glob_match?(pattern, relative) }
    end

    def glob_match?(pattern, relative)
      File.fnmatch(pattern, relative, FNM_FLAGS) ||
        (pattern.end_with?('/**') && relative.start_with?("#{pattern.delete_suffix('/**')}/"))
    end

    def auto_generated?(file)
      File.foreach(file) do |line|
        next if line.strip.empty?

        return line.match?(/\A\s*#\s*This file is auto-generated/i)
      end
      false
    rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
      false
    end
  end
end
