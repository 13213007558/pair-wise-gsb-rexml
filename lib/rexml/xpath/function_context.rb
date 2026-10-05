# frozen_string_literal: false

require_relative "../node"

module REXML
  class XPath
    # Runtime information passed to an extension function while an XPath query
    # is being evaluated.
    class FunctionContext
      attr_reader :node, :position, :size

      def initialize(node:, position:, size:)
        @node = node
        @position = position
        @size = size
        freeze
      end

      def [](name)
        case name.to_sym
        when :node
          @node
        when :position
          @position
        when :size
          @size
        end
      end

      def to_h
        {node: @node, position: @position, size: @size}
      end
    end

    # Describes one extension function and its optional XPath type contract.
    class Function
      TYPES = [:nodeset, :boolean, :number, :string].freeze
      TYPE_ALIASES = {node_set: :nodeset, :"node-set" => :nodeset}.freeze

      attr_reader :callback, :argument_types, :return_type

      def initialize(callback, argument_types: nil, return_type: nil,
                     arguments: nil, parameters: nil, returns: nil, **options)
        unless callback.respond_to?(:call)
          raise ArgumentError, "XPath function must respond to #call"
        end

        @callback = callback
        argument_types ||= arguments || parameters || []
        return_type ||= returns || options[:return]
        @argument_types = Array(argument_types).map { |type| normalize_type(type) }
        @return_type = return_type && normalize_type(return_type)
      end

      def call(arguments, context, functions)
        values = arguments.each_with_index.map do |argument, index|
          type = @argument_types[index]
          type ? convert(argument, type, functions) : argument
        end
        result = invoke_callback(values, context)
        @return_type ? convert(result, @return_type, functions) : result
      end

      private
      def invoke_callback(values, context)
        arity = @callback.arity
        if arity >= 0 && arity == values.size
          @callback.call(*values)
        else
          @callback.call(context, *values)
        end
      end

      def normalize_type(type)
        normalized = TYPE_ALIASES.fetch(type, type)
        normalized = normalized.to_sym unless normalized.is_a?(Symbol)
        unless TYPES.include?(normalized)
          raise ArgumentError, "unsupported XPath function type: #{type.inspect}"
        end
        normalized
      end

      def convert(value, type, functions)
        unless xpath_value?(value)
          raise TypeError, "can not convert #{value.class} to XPath #{type}"
        end

        case type
        when :nodeset
          functions.node_set(value)
        when :boolean
          functions.boolean(value)
        when :number
          functions.number(value)
        when :string
          convert_string(value, functions)
        end
      end

      def xpath_value?(value)
        case value
        when REXML::Node, Array, String, Numeric, true, false, nil
          true
        else
          false
        end
      end

      def convert_string(value, functions)
        functions.string(value)
      end
    end

    # Stores extension functions keyed by namespace URI and local name.
    class FunctionRegistry
      def initialize
        @functions = {}
      end

      def initialize_copy(other)
        super
        @functions = other.instance_variable_get(:@functions).dup
      end

      def register(namespace_uri, local_name, callable = nil,
                   argument_types: nil, return_type: nil,
                   arguments: nil, parameters: nil, returns: nil, **options, &block)
        target = callable || block
        function = Function.new(target,
                                argument_types: argument_types || arguments || parameters,
                                return_type: return_type || returns || options[:return])
        @functions[[namespace_uri.to_s, local_name.to_s]] = function
      end

      def [](namespace_uri, local_name)
        @functions[[namespace_uri.to_s, local_name.to_s]]
      end

      alias register_function register
    end

    # Explicit per-query namespaces, variables, and extension function registry.
    class Context
      attr_accessor :namespaces, :variables
      attr_reader :functions

      def initialize(namespaces: nil, variables: nil, functions: nil, strict: false)
        @namespaces = namespaces
        @variables = variables
        @functions = functions || FunctionRegistry.new
        @strict = strict
      end

      def strict?
        @strict
      end

      def register_function(*arguments, **options, &block)
        @functions.register(*arguments, **options, &block)
      end

      alias register register_function
    end
    QueryContext = Context
    EvaluationContext = FunctionContext
  end
end
