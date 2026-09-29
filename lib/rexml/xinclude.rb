# frozen_string_literal: false
require_relative "document"
require_relative "element"
require_relative "text"

module REXML
  # Processes XInclude (XML Inclusions) directives in a document.
  #
  # Supported features:
  # - +parse="xml"+ (default) and +parse="text"+ inclusions
  # - +xi:fallback+ for recoverable resource errors
  # - the +element()+ XPointer scheme (other schemes are reported as
  #   unsupported)
  # - relative +href+ resolution against +xml:base+, with +xml:base+ and
  #   +xml:lang+ fixup on included content
  # - nested inclusions and circular inclusion detection based on
  #   normalized URIs
  #
  # Resources are supplied exclusively by a caller-provided resolver.
  # The processor never touches the network or the file system by itself.
  # The resolver is any callable that receives the fully resolved,
  # normalized URI and returns the resource content as a String, or
  # +nil+ when the resource does not exist:
  #
  #   resources = {"http://example.com/doc.xml" => "<doc/>"}
  #   processor = REXML::XInclude.new(->(uri) { resources[uri] },
  #                                   base_uri: "http://example.com/main.xml")
  #   processor.process(document)        # expands in place
  #   processor.process_copy(document)   # expands a deep copy
  class XInclude
    # The XInclude namespace URI.
    NAMESPACE = "http://www.w3.org/2001/XInclude"

    # Generic fatal XInclude processing error.
    class Error < StandardError; end

    # A resource could not be loaded or used.  Recoverable through
    # +xi:fallback+.
    class ResourceError < Error; end

    # An XPointer scheme other than +element()+ was used.  This is a
    # fatal error and is not recoverable through +xi:fallback+.
    class UnsupportedSchemeError < Error
      def initialize(scheme)
        super("unsupported XPointer scheme: #{scheme}")
      end
    end

    # A circular inclusion chain was detected.  This is a fatal error
    # and is not recoverable through +xi:fallback+.
    class CircularIncludeError < Error
      def initialize(uri)
        super("circular XInclude reference: #{uri}")
      end
    end

    # +resolver+ is a callable mapping a normalized URI string to the
    # resource content (a String) or +nil+.  A block may be given
    # instead.  +base_uri+ is the base URI of the document being
    # processed, used to resolve relative +href+ values.
    def initialize(resolver = nil, base_uri: nil, &block)
      @resolver = resolver || block
      raise ArgumentError, "a resolver callable or block is required" unless @resolver
      @base_uri = base_uri && normalize_uri(base_uri)
    end

    # Expands all +xi:include+ elements in +document+, modifying it in
    # place.  Returns +document+.
    def process(document)
      stack = @base_uri ? [@base_uri] : []
      expand_inclusions(document, @base_uri, stack)
      document
    end

    # Expands all +xi:include+ elements in a deep copy of +document+ and
    # returns the copy.  +document+ itself is left untouched; no node is
    # shared between the original and the returned document.
    def process_copy(document)
      process(document.deep_clone)
    end

    private

    def expand_inclusions(root, base_uri, include_stack)
      while (include = find_include(root))
        expand_include(include, base_uri, include_stack)
      end
      root
    end

    def find_include(node)
      if include_element?(node)
        return node
      end
      node.elements.each do |child|
        found = find_include(child)
        return found if found
      end
      nil
    end

    def include_element?(node)
      node.is_a?(Element) and
        not node.is_a?(Document) and
        node.name == "include" and
        node.namespace == NAMESPACE
    end

    def fallback_element?(node)
      node.is_a?(Element) and
        node.name == "fallback" and
        node.namespace == NAMESPACE
    end

    def expand_include(include, base_uri, include_stack)
      href = include.attributes["href"]
      parse = include.attributes["parse"] || "xml"
      xpointer = include.attributes["xpointer"]
      encoding = include.attributes["encoding"]

      unless parse == "xml" or parse == "text"
        raise Error, "invalid xi:include parse attribute: #{parse.inspect}"
      end
      if href.nil? and xpointer.nil?
        raise Error, "xi:include requires an href or xpointer attribute"
      end

      include_base = compute_base(include, base_uri)
      uri = href && resolve_uri(include_base, href)
      fallback = include.elements.find {|child| fallback_element?(child) }

      begin
        nodes = load_replacement(include, uri, parse, xpointer, encoding,
                                 include_base, include_stack)
      rescue ResourceError
        raise unless fallback
        nodes = expand_fallback(fallback, include_base, include_stack)
      end

      replace_include(include, nodes)
    end

    def load_replacement(include, uri, parse, xpointer, encoding,
                         include_base, include_stack)
      if parse == "text"
        if xpointer
          raise Error, 'xpointer is not allowed with parse="text"'
        end
        raise Error, 'parse="text" requires an href attribute' unless uri
        check_circular!(uri, include_stack)
        content = fetch(uri)
        return [Text.new(decode_text(content, encoding, uri))]
      end

      if uri.nil?
        # Same-document inclusion through an xpointer.
        key = "self://#{xpointer}"
        check_circular!(key, include_stack)
        source_root = include.document.root
        raise ResourceError, "including document has no root" unless source_root
        selected = select_xpointer(source_root, xpointer, "the including document")
        node = selected.deep_clone
        node_base = include_base
        new_stack = include_stack + [key]
      else
        check_circular!(uri, include_stack)
        content = fetch(uri)
        document = parse_xml(content, uri)
        if xpointer
          selected = select_xpointer(document.root, xpointer, uri)
          node = selected.deep_clone
          node_base = compute_base(selected, uri)
        else
          node = document.root
          document.delete(node)
          node_base = compute_base(node, uri)
        end
        new_stack = include_stack + [uri]
      end

      fixup_node!(node, node_base, include)
      expand_inclusions(node, node_base, new_stack)
      [node]
    end

    def expand_fallback(fallback, include_base, include_stack)
      nodes = []
      fallback.children.each do |child|
        fallback.delete(child)
        nodes << child
      end
      nodes.each do |node|
        expand_inclusions(node, include_base, include_stack) if node.is_a?(Parent)
      end
      nodes
    end

    def replace_include(include, nodes)
      parent = include.parent
      nodes.each do |node|
        parent.insert_before(include, node)
      end
      parent.delete(include)
    end

    def check_circular!(key, include_stack)
      if include_stack.include?(key)
        raise CircularIncludeError, key
      end
    end

    def fetch(uri)
      content = @resolver.call(uri)
      if content.nil?
        raise ResourceError, "resource not found: #{uri}"
      end
      content
    rescue ResourceError
      raise
    rescue => error
      raise ResourceError, "failed to load #{uri}: #{error.message}"
    end

    def parse_xml(content, uri)
      Document.new(content)
    rescue ParseException, IOError => error
      raise ResourceError, "failed to parse #{uri}: #{error.message}"
    end

    def decode_text(content, encoding, uri)
      text = content.dup
      begin
        text.force_encoding(encoding || ::Encoding::UTF_8)
        unless text.valid_encoding?
          raise ResourceError, "invalid #{encoding || 'UTF-8'} content in #{uri}"
        end
        text.encode(::Encoding::UTF_8)
      rescue ResourceError
        raise
      rescue ::EncodingError, ArgumentError => error
        raise ResourceError, "failed to decode #{uri}: #{error.message}"
      end
    end

    # -- xml:base / xml:lang fixup -------------------------------------

    def fixup_node!(node, node_base, include)
      target_base = compute_base(include.parent, @base_uri)
      if node.attributes["xml:base"].nil? and node_base and target_base and
          node_base != target_base
        node.attributes["xml:base"] = node_base
      end
      if node.attributes["xml:lang"].nil?
        lang = inherited_lang(include)
        node.attributes["xml:lang"] = lang if lang
      end
    end

    def compute_base(element, document_base)
      chain = []
      node = element
      while node
        if node.is_a?(Element) and not node.is_a?(Document)
          xml_base = node.attributes["xml:base"]
          chain.unshift(xml_base) if xml_base
        end
        node = node.parent
      end
      base = document_base
      chain.each do |reference|
        base = base ? resolve_uri(base, reference) : normalize_uri(reference)
      end
      base
    end

    def inherited_lang(element)
      node = element
      while node
        if node.is_a?(Element) and not node.is_a?(Document)
          lang = node.attributes["xml:lang"]
          return lang if lang
        end
        node = node.parent
      end
      nil
    end

    # -- element() XPointer scheme -------------------------------------

    def select_xpointer(root, xpointer, resource_description)
      match = xpointer.strip.match(/\Aelement\((.*)\)\z/m)
      unless match
        scheme = xpointer.strip[/\A([A-Za-z_][\w.-]*)\(/, 1]
        if scheme
          raise UnsupportedSchemeError, scheme
        end
        raise Error, "unsupported XPointer syntax: #{xpointer}"
      end
      parts = match[1].split("/", -1)
      parts.shift while parts.first == ""
      node = root
      if parts.any? and parts.first !~ /\A\d+\z/
        id = parts.shift
        node = find_by_id(root, id)
        unless node
          raise ResourceError,
                "no element with ID #{id.inspect} in #{resource_description}"
        end
      end
      parts.each do |step|
        unless step =~ /\A[1-9]\d*\z/
          raise Error, "invalid element() XPointer step: #{step.inspect}"
        end
        node = node && node.elements[step.to_i]
        unless node
          raise ResourceError,
                "element() XPointer matched nothing in #{resource_description}"
        end
      end
      node
    end

    def find_by_id(element, id)
      return element if element_id(element) == id
      element.elements.each do |child|
        found = find_by_id(child, id)
        return found if found
      end
      nil
    end

    def element_id(element)
      element.attributes["xml:id"] || element.attributes["id"]
    end

    # -- URI resolution and normalization (RFC 3986) -------------------

    def resolve_uri(base, reference)
      reference = reference.to_s
      if base.nil? or base.empty? or reference =~ /\A[A-Za-z][A-Za-z0-9+.-]*:/
        return normalize_uri(reference)
      end
      if reference.start_with?("//")
        scheme = base[/\A[A-Za-z][A-Za-z0-9+.-]*:/]
        return normalize_uri("#{scheme}#{reference}")
      end
      if reference.start_with?("/")
        authority = base[%r{\A[A-Za-z][A-Za-z0-9+.-]*://[^/]*}]
        return normalize_uri("#{authority}#{reference}")
      end
      merged = base.sub(/[?#].*\z/, "").sub(%r{/[^/]*\z}, "/") + reference
      normalize_uri(merged)
    end

    def normalize_uri(uri)
      prefix = ""
      rest = uri.to_s
      if (match = rest.match(%r{\A([A-Za-z][A-Za-z0-9+.-]*://[^/]*)(.*)\z}m))
        prefix, rest = match[1], match[2]
      elsif (match = rest.match(/\A([A-Za-z][A-Za-z0-9+.-]*:)(.*)\z/m))
        prefix, rest = match[1], match[2]
      end
      suffix = rest[/[?#].*\z/] || ""
      path = rest[0, rest.length - suffix.length]
      "#{prefix}#{remove_dot_segments(path)}#{suffix}"
    end

    def remove_dot_segments(path)
      input = path.dup
      output = +""
      until input.empty?
        if input.start_with?("../")
          input = input[3..]
        elsif input.start_with?("./")
          input = input[2..]
        elsif input.start_with?("/./")
          input = "/#{input[3..]}"
        elsif input == "/."
          input = "/"
        elsif input.start_with?("/../")
          input = "/#{input[4..]}"
          output = output.sub(%r{/[^/]*\z}, "")
        elsif input == "/.."
          input = "/"
          output = output.sub(%r{/[^/]*\z}, "")
        elsif input == "." or input == ".."
          input = ""
        else
          index = input.index("/", input.start_with?("/") ? 1 : 0) || input.length
          output << input[0...index]
          input = input[index..] || ""
        end
      end
      output
    end
  end
end
