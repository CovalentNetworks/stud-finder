# frozen_string_literal: true

require 'open3'

module StudFinder
  class Churn
    Result = Struct.new(:counts, :zero_inflated, :zero_percentage, keyword_init: true)

    class Error < StandardError; end

    def initialize(repo_path:, files:, days:, stderr: $stderr)
      @repo_path = File.expand_path(repo_path)
      @files = files
      @days = days
      @stderr = stderr
    end

    def call
      stdout, _stderr, status = git_log
      raise Error, "Error: #{@repo_path} is not a git repository." unless status.success?

      counts = initial_counts
      file_set = counts.keys.to_h { |file| [file, true] }
      stdout.split("\0").each do |path|
        next if path.empty?

        relative = normalize_path(path)
        counts[relative] += 1 if file_set[relative]
      end

      Result.new(
        counts: counts,
        zero_inflated: zero_inflated?(counts),
        zero_percentage: zero_percentage(counts)
      ).tap { |result| warn_if_zero_inflated(result) }
    rescue Errno::ENOENT
      raise Error, 'Error: git not found in PATH.'
    end

    private

    def git_log
      Open3.capture3(
        'git', '-C', @repo_path, 'log',
        "--since=#{@days} days ago",
        '--format=tformat:',
        '-z',
        '--diff-filter=ACDMR',
        '--name-only'
      )
    end

    def initial_counts
      @files.to_h { |file| [file, 0] }
    end

    def normalize_path(path)
      absolute = File.expand_path(path, @repo_path)
      absolute.start_with?("#{@repo_path}/") ? absolute.delete_prefix("#{@repo_path}/") : path
    end

    def zero_inflated?(counts)
      return false if counts.empty?

      counts.values.count(&:zero?) > counts.length * 0.5
    end

    def zero_percentage(counts)
      return 0 if counts.empty?

      ((counts.values.count(&:zero?).to_f / counts.length) * 100).round
    end

    def warn_if_zero_inflated(result)
      return unless result.zero_inflated

      @stderr.puts "Warning: #{result.zero_percentage}% of files have zero churn in the last #{@days} days. " \
                   'Churn signal is weak. Consider --churn-days to widen the window.'
    end
  end
end
