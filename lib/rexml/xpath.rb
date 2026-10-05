# frozen_string_literal: false
require_relative 'functions'
require_relative 'xpath/function_context'
require_relative 'xpath_parser'

module REXML
  # Wrapper class.  Use this class to access the XPath functions.
  class XPath
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
    # options::
    #   +:context+ can be an REXML::XPath::Context. Its function registry is
    #   local to that query context, so functions with the same lexical name in
    #   different services do not affect each other.
    #
    #  XPath.first( node )
    #  XPath.first( doc, "//b"} )
    #  XPath.first( node, "a/x:b", { "x"=>"http://doofus" } )
    #  XPath.first( node, '/book/publisher/text()=$publisher', {}, {"publisher"=>"O'Reilly"})
    def XPath::first(element, path=nil, namespaces=nil, variables={}, options={})
      context = extract_context(namespaces, variables, options)
      if context
        result = parser_for_context(context).parse(path || "*", element)
        return result.is_a?(Array) ? result.flatten[0] : result
      end
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
      context = extract_context(namespaces, variables, options)
      if context
        return parser_for_context(context).parse(path || "*", element).each(&block)
      end
      raise "The namespaces argument, if supplied, must be a hash object." unless namespaces.nil? or namespaces.kind_of?(Hash)
      raise "The variables argument, if supplied, must be a hash object." unless variables.kind_of?(Hash)
      match(element, path, namespaces, variables, options).each( &block )
    end

    # Returns an array of nodes matching a given XPath.
    # Scalar query results are wrapped in an array for compatibility.
    def XPath::match(element, path=nil, namespaces=nil, variables={}, options={})
      context = extract_context(namespaces, variables, options)
      if context
        parser = parser_for_context(context)
      else
        raise "The namespaces argument, if supplied, must be a hash object." unless namespaces.nil? or namespaces.kind_of?(Hash)
        raise "The variables argument, if supplied, must be a hash object." unless variables.kind_of?(Hash)
        parser = XPathParser.new(**options)
        parser.namespaces = namespaces
        parser.variables = variables
      end
      path = "*" unless path
      parser.parse(path,element)
    end

    def XPath::extract_context(namespaces, variables, options)
      query_context = options[:context] if options.is_a?(Hash)
      query_context ||= namespaces if namespaces.is_a?(Context)
      query_context ||= variables if variables.is_a?(Context)
      query_context
    end
    private_class_method :extract_context

    def XPath::parser_for_context(context)
      XPathParser.new(context: context)
    end
    private_class_method :parser_for_context
  end
end
