# frozen_string_literal: true

require 'rubocop'
require 'set'

module StudFinder
  class FanIn
    Result = Struct.new(:counts, keyword_init: true)

    AUTOLOAD_ROOTS = %w[app lib].freeze
    PATH_ROOTS = (AUTOLOAD_ROOTS + %w[test]).freeze
    CLASS_OR_MODULE_TYPES = %i[class module].freeze

    def initialize(repo_path:, files:)
      @repo_path = File.expand_path(repo_path)
      @files = files
    end

    def call
      constants = constant_ownership
      references = reference_sets(constants.keys)

      counts = @files.to_h do |file|
        constant = constants[file]
        count = constant ? fan_in_count(file, constant, references) : 0

        [file, count]
      end

      Result.new(counts: counts)
    end

    private

    def constant_ownership
      @files.each_with_object({}) do |file, constants|
        next unless owned_path?(file)

        constants[file] = primary_constant(file) || zeitwerk_constant(file)
      end.compact
    end

    def reference_sets(source_files)
      source_files.to_h do |file|
        [file, references_for(file)]
      end
    end

    def fan_in_count(file, constant, references)
      references.count do |source_file, source_references|
        source_file != file && source_references.include?(constant)
      end
    end

    def primary_constant(file)
      ast = parse(file)
      return unless ast

      node = ast.each_node(*CLASS_OR_MODULE_TYPES).find do |candidate|
        candidate.each_ancestor.none? { |ancestor| CLASS_OR_MODULE_TYPES.include?(ancestor.type) }
      end

      constant_name(node&.identifier)
    end

    def references_for(file)
      ast = parse(file)
      return Set.new unless ast

      ast.each_node(:const).with_object(Set.new) do |node, references|
        next if nested_const_part?(node)

        name = constant_name(node)
        references << name if name
      end
    end

    def parse(file)
      source = File.read(File.join(@repo_path, file))
      RuboCop::ProcessedSource.new(source, RUBY_VERSION.to_f, file).ast
    rescue EncodingError, Errno::ENOENT, Parser::SyntaxError
      nil
    end

    def constant_name(node)
      return unless node&.const_type?

      node.const_name
    rescue StandardError
      nil
    end

    def nested_const_part?(node)
      node.each_ancestor.any?(&:const_type?)
    end

    def zeitwerk_constant(file)
      components = path_after_root(file)
      return unless components

      components = strip_app_concerns_namespace(components)
      components = components.reject { |component| component == 'concerns' }
      basename = components.pop&.delete_suffix('.rb')
      return if basename.nil? || basename.empty?

      (components + [basename]).map { |component| camelize(component) }.join('::')
    end

    def strip_app_concerns_namespace(components)
      concerns_index = components.index('concerns')
      return components unless concerns_index

      components[(concerns_index + 1)..] || []
    end

    def camelize(segment)
      segment.split('_').map(&:capitalize).join
    end

    def owned_path?(file)
      root_component(file)&.then { |root| AUTOLOAD_ROOTS.include?(root) }
    end

    def path_after_root(file)
      components = file.split('/')
      index = components.index { |component| PATH_ROOTS.include?(component) }
      return unless index

      components[(index + 1)..]
    end

    def root_component(file)
      file.split('/').find { |component| PATH_ROOTS.include?(component) }
    end
  end
end
