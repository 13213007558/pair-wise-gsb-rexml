# frozen_string_literal: false
require_relative 'functions'
require_relative 'xpath_parser'

module REXML
  # Wrapper class.  Use this class to access the XPath functions.
  class XPath
    class Context
      VALID_TYPES = [:string, :number, :boolean, :node_set].freeze

      attr_reader :namespaces, :variables, :functions, :strict

      def initialize(namespaces: nil, variables: nil, strict: false)
        @namespaces = namespaces
        @variables = variables || {}
        @functions = {}
        @strict = strict
      end

      def register_function(namespace_uri, local_name, *parameter_types,
                            return_type: nil, &block)
        namespace_uri = namespace_uri.to_s
        local_name = local_name.to_s
        if local_name.empty?
          raise ArgumentError, "XPath extension function local name can't be empty"
        end
        unless block
          raise ArgumentError, "XPath extension function requires a block"
        end
        invalid_types = (parameter_types + [return_type]).compact - VALID_TYPES
        unless invalid_types.empty?
          raise ArgumentError, "Unknown XPath type: #{invalid_types.first.inspect}"
        end
        @functions[[namespace_uri, local_name]] = {
          parameter_types: parameter_types,
          return_type: return_type,
          block: block
        }
      end
    end

    class FunctionContext
      attr_reader :node, :position, :size

      def initialize(node:, position:, size:)
        @node = node
        @position = position
        @size = size
        freeze
      end

      alias current_node node
      alias last size
    end

    # A base Hash object, supposing to be used when initializing a
    # default empty namespaces set, but is currently unused.
    # TODO: either set the namespaces=EMPTY_HASH, or deprecate this.
    EMPTY_HASH = {}

    # Finds and returns the first node that matches the supplied xpath.
    # element::
    #   The context element
    # path::
    #   The xpath to search for.  If not supplied or nil, returns the first
    #   node matching '*'.
    # namespaces::
    #   If supplied, a Hash which defines a namespace mapping.
    # variables::
    #   If supplied, a Hash which maps $variables in the query
    #   to values. This can be used to avoid XPath injection attacks
    #   or to automatically handle escaping string values.
    #
    #  XPath.first( node )
    #  XPath.first( doc, "//b"} )
    #  XPath.first( node, "a/x:b", { "x"=>"http://doofus" } )
    #  XPath.first( node, '/book/publisher/text()=$publisher', {}, {"publisher"=>"O'Reilly"})
    def XPath::first(element, path=nil, namespaces=nil, variables={}, options={})
      namespaces, variables, options = prepare_query_arguments(
        namespaces, variables, options
      )
      raise "The namespaces argument, if supplied, must be a hash object." unless namespaces.nil? or namespaces.kind_of?(Hash)
      raise "The variables argument, if supplied, must be a hash object." unless variables.kind_of?(Hash)
      match(element, path, namespaces, variables, options).flatten[0]
    end

    # Iterates over nodes that match the given path, calling the supplied
    # block with the match.
    # element::
    #   The context element
    # path::
    #   The xpath to search for.  If not supplied or nil, defaults to '*'
    # namespaces::
    #   If supplied, a Hash which defines a namespace mapping
    # variables::
    #   If supplied, a Hash which maps $variables in the query
    #   to values. This can be used to avoid XPath injection attacks
    #   or to automatically handle escaping string values.
    #
    #  XPath.each( node ) { |el| ... }
    #  XPath.each( node, '/*[@attr='v']' ) { |el| ... }
    #  XPath.each( node, 'ancestor::x' ) { |el| ... }
    #  XPath.each( node, '/book/publisher/text()=$publisher', {}, {"publisher"=>"O'Reilly"}) \
    #    {|el| ... }
    def XPath::each(element, path=nil, namespaces=nil, variables={}, options={}, &block)
      namespaces, variables, options = prepare_query_arguments(
        namespaces, variables, options
      )
      raise "The namespaces argument, if supplied, must be a hash object." unless namespaces.nil? or namespaces.kind_of?(Hash)
      raise "The variables argument, if supplied, must be a hash object." unless variables.kind_of?(Hash)
      match(element, path, namespaces, variables, options).each( &block )
    end

    # Returns an array of nodes matching a given XPath.
    def XPath::match(element, path=nil, namespaces=nil, variables={}, options={})
      namespaces, variables, options, context = prepare_query_arguments(
        namespaces, variables, options, true
      )
      parser = XPathParser.new(**options)
      parser.namespaces = namespaces
      parser.variables = variables
      parser.query_context = context
      path = "*" unless path
      parser.parse(path, element)
    end

    def XPath.prepare_query_arguments(namespaces, variables, options,
                                      include_context=false)
      context = options[:context]
      namespaces ||= context&.namespaces
      variables = context&.variables if variables.nil? || variables.empty?
      variables ||= {}
      parser_options = options.dup
      parser_options.delete(:context)
      if context && !parser_options.key?(:strict)
        parser_options[:strict] = context.strict
      end
      arguments = [namespaces, variables, parser_options]
      arguments << context if include_context
      arguments
    end
    private_class_method :prepare_query_arguments
  end
end
