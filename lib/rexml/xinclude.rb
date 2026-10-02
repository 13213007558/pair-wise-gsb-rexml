# frozen_string_literal: false
require "uri"

# rexml/document requires this file at its bottom; only pull it in
# when this file is loaded standalone.
require_relative "document" unless defined?(REXML::Document)

module REXML
  # Processes XInclude 1.0 (https://www.w3.org/TR/xinclude/) include
  # elements in a REXML document tree.
  #
  # Supported:
  # - +parse="xml"+ (default) and +parse="text"+.
  # - +xi:fallback+ for resource errors.
  # - Nested includes, including includes inside fallback content.
  # - Inclusion loop detection with the full reference chain.
  # - Base URI (+xml:base+) and language (+xml:lang+) fixup when
  #   included content is transplanted into the including document.
  #
  # Not supported (rejected with a fatal error):
  # - The +xpointer+ attribute.
  #
  # Every resource is retrieved through the resolver given to
  # #initialize.  The default resolver reads local files only and
  # refuses to access the network.
  #
  #   resolver = ->(uri) { File.read(uri) }
  #   document = REXML::Document.new(File.read("doc.xml"))
  #   REXML::XInclude.new(resolver: resolver).process(document,
  #                                                   base_uri: "doc.xml")
  class XInclude
    # The XInclude 1.0 namespace URI.
    NAMESPACE = "http://www.w3.org/2001/XInclude"

    # Base class for all XInclude processing errors.
    class Error < StandardError; end

    # A fatal error as defined by the XInclude specification.
    # Fallback does not apply to fatal errors.
    class FatalError < Error; end

    # A resource error as defined by the XInclude specification.
    # When an xi:include element has an xi:fallback child, the
    # fallback content is used instead of raising this error.
    class ResourceError < Error
      # The resolved URI of the resource that could not be retrieved.
      attr_reader :href

      def initialize(message=nil, href: nil)
        @href = href
        super(message)
      end
    end

    # Raised when a direct or indirect inclusion loop is detected.
    # The full reference chain is available via #chain and is also
    # included in the error message.
    class LoopError < ResourceError
      # The chain of resolved URIs leading to (and including) the
      # repeated resource, e.g. ["a.xml", "b.xml", "a.xml"].
      attr_reader :chain

      def initialize(chain)
        @chain = chain
        super("XInclude loop detected: #{chain.join(' -> ')}",
              href: chain.last)
      end
    end

    # Raised when an xi:include element uses the xpointer attribute,
    # which this implementation does not support.
    class XPointerNotSupportedError < FatalError
      def initialize(xpointer)
        super("xpointer is not supported: #{xpointer.inspect}")
      end
    end

    # The default resolver.  Reads local files (plain paths and
    # file: URIs) and refuses everything else, so no network access
    # happens unless the caller explicitly provides a resolver that
    # performs it.
    DEFAULT_RESOLVER = lambda do |uri|
      path =
        if uri =~ /\A[A-Za-z]:[\\\/]/ # Windows drive letter path
          uri
        elsif uri =~ /\A[A-Za-z][A-Za-z0-9+.-]*:/
          scheme = uri.split(":", 2).first.downcase
          unless scheme == "file"
            raise ResourceError.new(
              "network access is disabled by the default resolver: #{uri}",
              href: uri)
          end
          URI::DEFAULT_PARSER.unescape(URI.parse(uri).path)
        else
          uri
        end
      File.read(path)
    rescue ResourceError
      raise
    rescue SystemCallError, IOError => error
      raise ResourceError.new("cannot retrieve #{uri}: #{error.message}",
                              href: uri)
    end

    # Creates a processor.
    #
    # +resolver+ is a callable that receives the resolved (absolute)
    # URI of a resource as a String and returns its content as a
    # String.  It may raise REXML::XInclude::ResourceError to signal
    # a resource error; any other exception is wrapped into one.
    def initialize(resolver: DEFAULT_RESOLVER)
      @resolver = resolver
    end

    # Resolves +href+ against +base+ and returns the resulting URI
    # string.  Both absolute URIs (with a scheme) and plain file
    # system paths are supported as base.
    def self.resolve_uri(base, href)
      return href if base.nil? or base.empty?
      return href if href =~ /\A[A-Za-z][A-Za-z0-9+.-]*:/
      if base =~ /\A[A-Za-z][A-Za-z0-9+.-]*:/
        URI.join(base, href).to_s
      else
        directory = base.sub(%r{[^/]*\z}, "")
        normalize_path(directory + href)
      end
    end

    # Processes every xi:include element in +document+, replacing
    # each one with the content it references, and returns
    # +document+.
    #
    # +base_uri+ is the base URI of +document+ itself.  Relative
    # href values are resolved against it, and it seeds inclusion
    # loop detection so that a document that (indirectly) includes
    # itself is reported as a loop.
    def process(document, base_uri: nil)
      chain = base_uri.nil? ? [] : [base_uri]
      process_children(document, base_uri, chain)
      document
    end

    private

    def self.normalize_path(path)
      absolute = path.start_with?("/")
      trailing = path.end_with?("/") and path != "/"
      segments = []
      path.split("/").each do |segment|
        next if segment.empty? or segment == "."
        if segment == ".."
          if !segments.empty? and segments.last != ".."
            segments.pop
          elsif !absolute
            segments << ".."
          end
        else
          segments << segment
        end
      end
      result = segments.join("/")
      result = "/#{result}" if absolute
      result += "/" if trailing and !result.end_with?("/")
      result.empty? ? (absolute ? "/" : ".") : result
    end

    def xinclude_element?(element, name)
      element.is_a?(Element) and
        element.name == name and
        element.namespace == NAMESPACE
    end

    def process_children(node, base_uri, chain)
      node.children.each do |child|
        process_node(child, base_uri, chain)
      end
    end

    def process_node(node, base_uri, chain)
      return unless node.is_a?(Element)
      if xinclude_element?(node, "include")
        expand_include(node, base_uri, chain)
      else
        process_children(node, base_uri_for(node, base_uri), chain)
      end
    end

    # The base URI in scope for +element+, taking xml:base
    # attributes on the element itself into account.
    def base_uri_for(element, inherited)
      value = element.attributes["xml:base"]
      value.nil? ? inherited : self.class.resolve_uri(inherited, value)
    end

    # The xml:lang value in scope at +element+, or nil.
    def inherited_language(element)
      current = element
      while current.is_a?(Element)
        language = current.attributes["xml:lang"]
        return language if language
        current = current.parent
      end
      nil
    end

    def expand_include(include_element, base_uri, chain)
      location_base = base_uri_for(include_element, base_uri)

      xpointer = include_element.attributes["xpointer"]
      raise XPointerNotSupportedError.new(xpointer) if xpointer

      href = include_element.attributes["href"]
      if href.nil? or href.empty?
        raise FatalError, "xi:include requires a non-empty href attribute"
      end

      parse = include_element.attributes["parse"] || "xml"
      unless parse == "xml" or parse == "text"
        raise FatalError, "unsupported xi:include parse value: #{parse.inspect}"
      end

      fallback = extract_fallback(include_element)
      resolved = self.class.resolve_uri(location_base, href)

      replacement = nil
      fallback_used = false
      begin
        replacement =
          if parse == "xml"
            acquire_xml(include_element, resolved, location_base, chain)
          else
            acquire_text(resolved)
          end
      rescue ResourceError
        raise unless fallback
        replacement = fallback.children
        fallback_used = true
      end

      parent = include_element.parent
      inserted = replacement.dup
      inserted.each do |new_node|
        parent.insert_before(include_element, new_node)
      end
      parent.delete(include_element)

      if fallback_used
        inserted.each do |new_node|
          process_node(new_node, location_base, chain)
        end
      end
    end

    def extract_fallback(include_element)
      fallback = nil
      include_element.children.each do |child|
        if xinclude_element?(child, "fallback")
          if fallback
            raise FatalError,
                  "xi:include may not have more than one xi:fallback child"
          end
          fallback = child
        elsif child.is_a?(Element)
          raise FatalError,
                "xi:include may only contain xi:fallback children"
        elsif child.is_a?(Text) and child.value.strip != ""
          raise FatalError, "xi:include may not contain text"
        end
      end
      fallback
    end

    def acquire_xml(include_element, resolved, location_base, chain)
      if chain.include?(resolved)
        raise LoopError.new(chain + [resolved])
      end
      content = retrieve(resolved)
      included_document =
        begin
          Document.new(content)
        rescue ParseException => error
          raise FatalError,
                "included resource #{resolved} is not well-formed XML: " \
                "#{error.message}"
        end
      if included_document.root.nil?
        raise FatalError,
              "included resource #{resolved} is not well-formed XML: " \
              "no document element"
      end
      process_children(included_document, resolved, chain + [resolved])
      items = included_document.children.select do |child|
        child.is_a?(Element) or
          child.is_a?(Comment) or
          child.is_a?(Instruction)
      end
      language = inherited_language(include_element)
      items.each do |item|
        next unless item.is_a?(Element)
        fixup_base_uri(item, resolved, location_base)
        fixup_language(item, language)
      end
      items
    end

    def acquire_text(resolved)
      content = retrieve(resolved)
      if content.encoding == ::Encoding::ASCII_8BIT
        content = content.dup.force_encoding(::Encoding::UTF_8)
      end
      [Text.new(content, true, nil, false)]
    end

    # Base URI fixup (XInclude 1.0 section 4.5.5): when the base URI
    # of the included infoset differs from the base URI at the
    # include location, record it on the top-level included elements
    # so that relative references inside them keep resolving against
    # the resource they actually came from.
    def fixup_base_uri(item, included_base, location_base)
      return if included_base.nil? or included_base == location_base
      existing = item.attributes["xml:base"]
      if existing
        item.attributes["xml:base"] =
          self.class.resolve_uri(included_base, existing)
      else
        item.attributes["xml:base"] = included_base
      end
    end

    # Language fixup (XInclude 1.0 section 4.5.5): included items
    # without their own xml:lang inherit the language in scope at
    # the include location.
    def fixup_language(item, language)
      return if language.nil?
      return if item.attributes["xml:lang"]
      item.attributes["xml:lang"] = language
    end

    def retrieve(resolved)
      content =
        begin
          @resolver.call(resolved)
        rescue ResourceError
          raise
        rescue => error
          raise ResourceError.new(
            "failed to retrieve #{resolved}: #{error.message}",
            href: resolved)
        end
      if content.nil?
        raise ResourceError.new("resolver returned no content for #{resolved}",
                                href: resolved)
      end
      content
    end
  end
end
