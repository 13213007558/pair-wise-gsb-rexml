# frozen_string_literal: false

require 'set'
require_relative 'node'

module REXML
  # If you add a method, keep in mind two things:
  # (1) the first argument will always be a list of nodes from which to
  # filter.  In the case of context methods (such as position), the function
  # should return an array with a value for each child in the array.
  # (2) all method calls from XML will have "-" replaced with "_".
  # Therefore, in XML, "local-name()" is identical (and actually becomes)
  # "local_name()"
  class FunctionsClass # :nodoc:
    attr_reader :context

    def initialize
      @context = nil
      @node_indexes = nil
      @extensions = {}
    end

    AVAILABLE_FUNCTIONS = %w[
      boolean
      ceiling
      concat
      contains
      count
      false
      floor
      id
      lang
      last
      local-name
      name
      namespace-uri
      normalize-space
      not
      number
      position
      round
      starts-with
      string
      string-length
      substring
      substring-after
      substring-before
      sum
      translate
      true
    ].to_set.freeze

    def context=(value); @context = value; end

    def extensions=(value)
      @extensions = value || {}
    end

    # The evaluation's shared index cache, set by XPathParser so that sorting
    # here does not re-index the same children for every call.  It is
    # nil for the shared Functions instance, which is reachable without going
    # through XPathParser; sort then caches for one call only.
    def node_indexes=(value); @node_indexes = value; end

    # Returns the last node of the given list of nodes.
    def last( )
      @context[:size]
    end

    def position( )
      @context[:position]
    end

    # Returns the size of the given list of nodes.
    def count( node_set )
      node_set.size
    end

    # Since REXML is non-validating, this method is not implemented as it
    # requires a DTD
    def id( object )
      []
    end

    def local_name(node_set=nil)
      target_named_node(node_set)&.local_name || ""
    end

    def namespace_uri( node_set=nil )
      target_named_node(node_set)&.namespace || ""
    end

    def name( node_set=nil )
      target_named_node(node_set)&.expanded_name || ""
    end

    # Helper method.
    def target_named_node(node_set = nil)
      node =
        case node_set
        when nil
          @context[:node]
        when Array
          XPathParser.sort(node_set, @node_indexes).first
        end
      node if node.respond_to?(:namespace)
    end

    # A node-set is converted to a string by returning the string-value of the
    # node in the node-set that is first in document order. If the node-set is
    # empty, an empty string is returned.
    #
    # A number is converted to a string as follows
    #
    # NaN is converted to the string NaN
    #
    # positive zero is converted to the string 0
    #
    # negative zero is converted to the string 0
    #
    # positive infinity is converted to the string Infinity
    #
    # negative infinity is converted to the string -Infinity
    #
    # if the number is an integer, the number is represented in decimal form
    # as a Number with no decimal point and no leading zeros, preceded by a
    # minus sign (-) if the number is negative
    #
    # otherwise, the number is represented in decimal form as a Number
    # including a decimal point with at least one digit before the decimal
    # point and at least one digit after the decimal point, preceded by a
    # minus sign (-) if the number is negative; there must be no leading zeros
    # before the decimal point apart possibly from the one required digit
    # immediately before the decimal point; beyond the one required digit
    # after the decimal point there must be as many, but only as many, more
    # digits as are needed to uniquely distinguish the number from all other
    # IEEE 754 numeric values.
    #
    # The boolean false value is converted to the string false. The boolean
    # true value is converted to the string true.
    #
    # An object of a type other than the four basic types is converted to a
    # string in a way that is dependent on that type.
    def string( object=@context[:node] )
      if object.respond_to?(:node_type)
        case object.node_type
        when :attribute
          object.value
        when :element
          string_value(object)
        when :document
          string_value(object.root)
        when :processing_instruction
          object.content
        else
          object.to_s
        end
      else
        case object
        when Array
          string(XPathParser.sort(object, @node_indexes).first)
        when Float
          if object.nan?
            "NaN"
          else
            integer = object.to_i
            if object == integer
              "%d" % integer
            else
              object.to_s
            end
          end
        else
          object.to_s
        end
      end
    end

    # A node-set is converted to a string by
    # returning the concatenation of the string-value
    # of each of the children of the node in the
    # node-set that is first in document order.
    # If the node-set is empty, an empty string is returned.
    def string_value( o )
      rv = ""
      o.children.each { |e|
        if e.node_type == :text
          rv << e.to_s
        elsif e.node_type == :element
          rv << string_value( e )
        end
      }
      rv
    end

    def concat( *objects )
      concatenated = ""
      objects.each do |object|
        concatenated << string(object)
      end
      concatenated
    end

    # Fixed by Mike Stok
    def starts_with( string, test )
      string(string).index(string(test)) == 0
    end

    # Fixed by Mike Stok
    def contains( string, test )
      string(string).include?(string(test))
    end

    # Kouhei fixed this
    def substring_before( string, test )
      ruby_string = string(string)
      ruby_index = ruby_string.index(string(test))
      if ruby_index.nil?
        ""
      else
        ruby_string[ 0...ruby_index ]
      end
    end

    # Kouhei fixed this too
    def substring_after( string, test )
      ruby_string = string(string)
      ruby_test = string(test)
      ruby_index = ruby_string.index(ruby_test)
      if ruby_index.nil?
        ""
      else
        ruby_string[(ruby_index + ruby_test.length)..-1]
      end
    end

    # Take equal portions of Mike Stok and Sean Russell; mix
    # vigorously, and pour into a tall, chilled glass.  Serves 10,000.
    def substring( string, start, length=nil )
      ruby_string = string(string)
      ruby_length = if length.nil?
                      ruby_string.length.to_f
                    else
                      number(length)
                    end
      ruby_start = number(start)

      # Handle the special cases
      return '' if (
        ruby_length.nan? or
        ruby_start.nan? or
        ruby_start.infinite?
      )

      infinite_length = ruby_length.infinite? == 1
      ruby_length = ruby_string.length if infinite_length

      # Now, get the bounds.  The XPath bounds are 1..length; the ruby bounds
      # are 0..length.  Therefore, we have to offset the bounds by one.
      ruby_start = round(ruby_start) - 1
      ruby_length = round(ruby_length)

      if ruby_start < 0
       ruby_length += ruby_start unless infinite_length
       ruby_start = 0
      end
      return '' if ruby_length <= 0
      ruby_string[ruby_start,ruby_length]
    end

    def string_length( object=@context[:node] )
      string(object).length
    end

    def normalize_space( object=@context[:node] )
      string(object).strip.gsub(/\s+/um, ' ')
    end

    # This is entirely Mike Stok's beast
    def translate( string, tr1, tr2 )
      from = string(tr1)
      to = string(tr2)

      # the map is our translation table.
      #
      # if a character occurs more than once in the
      # from string then we ignore the second &
      # subsequent mappings
      #
      # if a character maps to nil then we delete it
      # in the output.  This happens if the from
      # string is longer than the to string
      #
      # there's nothing about - or ^ being special in
      # http://www.w3.org/TR/xpath#function-translate
      # so we don't build ranges or negated classes

      map = Hash.new
      0.upto(from.length - 1) { |pos|
        from_char = from[pos]
        unless map.has_key? from_char
          map[from_char] =
          if pos < to.length
            to[pos]
          else
            nil
          end
        end
      }

      if ''.respond_to? :chars
        string(string).chars.collect { |c|
          if map.has_key? c then map[c] else c end
        }.compact.join
      else
        string(string).unpack('U*').collect { |c|
          if map.has_key? c then map[c] else c end
        }.compact.pack('U*')
      end
    end

    def boolean(object=@context[:node])
      case object
      when true, false
        object
      when Float
        return false if object.zero?
        return false if object.nan?
        true
      when Numeric
        not object.zero?
      when String
        not object.empty?
      when Array
        not object.empty?
      else
        object ? true : false
      end
    end

    # UNTESTED
    def not( object )
      not boolean( object )
    end

    # UNTESTED
    def true( )
      true
    end

    # UNTESTED
    def false(  )
      false
    end

    # UNTESTED
    def lang( language )
      lang = false
      node = @context[:node]
      attr = nil
      until node.nil?
        if node.node_type == :element
          attr = node.attributes["xml:lang"]
          unless attr.nil?
            lang = compare_language(string(language), attr)
            break
          else
          end
        end
        node = node.parent
      end
      lang
    end

    def compare_language lang1, lang2
      lang1 = lang1.downcase
      lang2 = lang2.downcase
      lang2 == lang1 or lang2.start_with?("#{lang1}-")
    end

    # a string that consists of optional whitespace followed by an optional
    # minus sign followed by a Number followed by whitespace is converted to
    # the IEEE 754 number that is nearest (according to the IEEE 754
    # round-to-nearest rule) to the mathematical value represented by the
    # string; any other string is converted to NaN
    #
    # boolean true is converted to 1; boolean false is converted to 0
    #
    # a node-set is first converted to a string as if by a call to the string
    # function and then converted in the same way as a string argument
    #
    # an object of a type other than the four basic types is converted to a
    # number in a way that is dependent on that type
    def number(object=@context[:node])
      case object
      when true
        Float(1)
      when false
        Float(0)
      when Array
        number(string(object))
      when Numeric
        object.to_f
      else
        str = string(object)
        case str.strip
        when /\A\s*(-?(?:\d+(?:\.\d*)?|\.\d+))\s*\z/
          $1.to_f
        else
          Float::NAN
        end
      end
    end

    def sum( nodes )
      nodes = [nodes] unless nodes.kind_of? Array
      nodes.inject(0) { |r,n| r + number(string(n)) }
    end

    def floor( number )
      number(number).floor
    end

    def ceiling( number )
      number(number).ceil
    end

    def round( number )
      number = number(number)
      begin
        neg = number.negative?
        number = number.abs.round
        neg ? -number : number
      rescue FloatDomainError
        number
      end
    end

    def call(name, args:, fallback: nil, namespace: nil, function_context: nil,
             node_indexes: nil, lexical: true)
      name = name.to_s
      normalized_name = name.tr('_', '-')
      if namespace
        extension = @extensions[[namespace, name]]
        if extension
          return call_extension(extension, args, function_context, node_indexes)
        end
        unless lexical
          extension = @extensions[[namespace, normalized_name]]
          if extension
            return call_extension(extension, args, function_context, node_indexes)
          end
        end
        return fallback unless fallback.nil?
        raise ArgumentError, "Unknown XPath extension function: #{namespace}:#{name}"
      elsif (!lexical || AVAILABLE_FUNCTIONS.include?(name)) &&
            AVAILABLE_FUNCTIONS.include?(normalized_name)
        __send__(normalized_name.tr('-', '_'), *args)
      else
        extension = @extensions[["", name]]
        if extension
          return call_extension(extension, args, function_context, node_indexes)
        end
        extension = @extensions[["", normalized_name]]
        if extension
          return call_extension(extension, args, function_context, node_indexes)
        end
        return fallback unless fallback.nil?
        raise ArgumentError, "Unknown XPath function: #{name}"
      end
    end

    def coerce_extension_argument(value, type)
      case type
      when :string
        string(value)
      when :number
        number(value)
      when :boolean
        boolean(value)
      when :node_set
        normalize_node_set(value)
      else
        value
      end
    end

    def coerce_extension_result(value, type, node_indexes = nil)
      case type
      when nil
        case value
        when Array
          normalize_node_set(value, node_indexes: node_indexes)
        when String, Numeric, true, false
          value
        else
          raise invalid_extension_result(value)
        end
      when :node_set
        normalize_node_set(value, node_indexes: node_indexes)
      when :string
        unless value.is_a?(String)
          raise invalid_extension_result(value, "string")
        end
        value
      when :number
        unless value.is_a?(Numeric)
          raise invalid_extension_result(value, "number")
        end
        value.to_f
      when :boolean
        unless value == true || value == false
          raise invalid_extension_result(value, "boolean")
        end
      end
    end

    def normalize_node_set(value, node_indexes: @node_indexes)
      nodes = value.is_a?(Array) ? value : [value]
      unless nodes.all? { |node| node.is_a?(Node) }
        raise TypeError, "XPath node-set must contain only REXML::Node objects"
      end
      unique_nodes = Set.new.compare_by_identity
      nodes.each { |node| unique_nodes << node }
      XPathParser.sort(unique_nodes.to_a, node_indexes)
    end

    def extension?(namespace, name)
      @extensions.key?([namespace.to_s, name.to_s])
    end

    def call_extension(extension, args, context, node_indexes)
      parameter_types = extension[:parameter_types]
      unless args.size == parameter_types.size
        raise ArgumentError,
              "wrong number of arguments (#{args.size} for #{parameter_types.size})"
      end
      arguments = args.each_with_index.collect do |arg, index|
        if parameter_types[index] == :node_set && !arg.is_a?(Array)
          raise TypeError, "XPath extension argument must be a node-set: #{arg.inspect}"
        end
        coerce_extension_argument(arg, parameter_types[index])
      end
      result = extension[:block].call(context, *arguments)
      coerce_extension_result(result, extension[:return_type], node_indexes)
    end

    def invalid_extension_result(value, type = nil)
      expected = type ? " #{type}" : " an XPath value"
      TypeError.new("XPath extension function must return#{expected}: #{value.inspect}")
    end

    # For compatibility. Use `call` instead.
    def send(name, *args)
      call(name.to_s.tr('_', '-'), args: args, fallback: [])
    end
  end

  # Using this singleton instance may cause thread-safety issues.
  # Consider instantiating your own FunctionsClass object.
  Functions = FunctionsClass.new # :nodoc:
end
