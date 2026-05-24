# frozen_string_literal: true

require 'json'
require 'open3'
require 'set'
require 'timeout'

module StudFinder
  class JsFanIn
    Result = Struct.new(:counts, :warnings, keyword_init: true)

    TOOL_MISSING = 'js_tools_missing'
    TIMEOUT = 'js_depcruise_timeout'

    def initialize(repo_path:, files:, js_timeout: 60, stderr: $stderr)
      @repo_path = File.expand_path(repo_path)
      @files = files
      @js_timeout = js_timeout
      @stderr = stderr
    end

    def call
      return missing_tools unless node_available?

      depcruise = depcruise_binary
      return missing_tools unless depcruise

      stdout, _stderr, status = run_depcruise(depcruise)
      return missing_tools unless status.success?

      Result.new(counts: parse(stdout), warnings: [])
    rescue Timeout::Error
      warn(TIMEOUT)
      Result.new(counts: zero_counts, warnings: [TIMEOUT])
    rescue JSON::ParserError, KeyError, TypeError
      missing_tools
    end

    private

    def node_available?
      _stdout, _stderr, status = Open3.capture3('node', '--version')
      status.success?
    rescue Errno::ENOENT
      false
    end

    def depcruise_binary
      Dir.chdir(@repo_path) do
        local = 'node_modules/.bin/depcruise'
        return local if File.executable?(local)
      end

      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).each do |dir|
        candidate = File.join(dir, 'depcruise')
        return 'depcruise' if File.file?(candidate) && File.executable?(candidate)
      end

      nil
    end

    def run_depcruise(depcruise)
      Timeout.timeout(@js_timeout) do
        Dir.chdir(@repo_path) do
          Open3.capture3(depcruise, '--output-type', 'json', '.')
        end
      end
    end

    def parse(stdout)
      payload = JSON.parse(stdout)
      file_set = @files.to_h { |file| [file, true] }
      counts = zero_counts
      seen_edges = Set.new

      Array(payload.fetch('modules')).each do |mod|
        source = normalize_path(mod.fetch('source'))
        next unless file_set[source]

        Array(mod['dependencies']).each do |dependency|
          target = normalize_path(dependency['resolved'].to_s)
          next unless file_set[target]
          next if target == source
          next unless seen_edges.add?([source, target])

          counts[target] += 1
        end
      end

      counts
    end

    def normalize_path(path)
      path.delete_prefix('./')
    end

    def missing_tools
      warn(TOOL_MISSING)
      Result.new(counts: zero_counts, warnings: [TOOL_MISSING])
    end

    def zero_counts
      @files.to_h { |file| [file, 0] }
    end

    def warn(code)
      @stderr.puts "Warning: #{code}"
    end
  end
end
