# frozen_string_literal: false

require "uri"

require_relative "document"
require_relative "text"

module REXML
  # \Module \REXML::XInclude implements {XML Inclusions
  # (XInclude) 1.0}[https://www.w3.org/TR/xinclude/] processing for
  # tree API documents.
  #
  # Resources are never read from the filesystem or the network by this
  # module.  Every +href+ is passed to a caller supplied resolver, which
  # makes it possible to include in-memory resources only:
  #
  #   resources = {"greeting.xml" => "<greeting>Hello</greeting>"}
  #   resolver = ->(uri) { resources[uri] }
  #   document = REXML::Document.new(<<-XML)
  #     <doc xmlns:xi="http://www.w3.org/2001/XInclude">
  #       <xi:include href="greeting.xml"/>
  #     </doc>
  #   XML
  #   expanded = REXML::XInclude.process(document, resolver: resolver)
  #
  # The resolver is called with the resolved (absolute, normalized) URI
  # of the resource and must return the resource content as a String
  # (or an object responding to +read+), or +nil+ when the resource is
  # not available.  Exceptions raised by the resolver are treated as
  # resource failures and trigger the xi:fallback mechanism.
  #
  # By default the source document is left untouched and an expanded
  # copy is returned.  Pass <tt>in_place: true</tt> to expand the given
  # document itself.  Nodes of the source document and nodes of the
  # returned document never mix: the returned document only contains
  # nodes owned by itself.
  module XInclude
    # The XInclude namespace URI.
    NAMESPACE = "http://www.w3.org/2001/XInclude"

    # Base class for all errors raised by XInclude processing.
    class Error < StandardError; end

    # Raised when a resource cannot be loaded, parsed, or selected and
    # no applicable xi:fallback exists.
    class ResourceError < Error; end

    # Raised when an inclusion loop is detected.  URIs are normalized
    # before comparison, so the same resource referenced through
    # different spellings (for example "a.xml" and "./a.xml") is still
    # recognized as a loop.
    class InclusionLoopError < Error; end

    # Raised for XPointer schemes other than element().
    class UnsupportedSchemeError < Error; end

    # Raised for malformed xi:include or xi:fallback usage.
    class InvalidIncludeError < Error; end

    class << self
      # Expands all xi:include elements in +document+.
      #
      # +resolver+ must respond to +call+ and accept the resolved URI
      # string of the resource to load.
      #
      # +base+ is the base URI of +document+ itself, used to resolve
      # relative +href+ values when the document does not carry an
      # xml:base attribute.
      #
      # With <tt>in_place: false</tt> (the default) the expansion is
      # performed on a deep copy and +document+ is not modified.  With
      # <tt>in_place: true</tt> +document+ itself is expanded.  In both
      # cases the expanded document is returned.
      def process(document, resolver:, base: nil, in_place: false)
        target = in_place ? document : document.deep_clone
        Processor.new(resolver).process(target, base)
        target
      end
    end

    # @private
    class Processor
      def initialize(resolver)
        unless resolver.respond_to?(:call)
          raise ArgumentError, "resolver must respond to #call"
        end
        @resolver = resolver
      end

      def process(document, base)
        base = base ? normalize_uri(base) : nil
        process_children(document, base, nil, [])
        document
      end

      private

      def process_children(parent, base, lang, chain)
        parent.children.each do |child|
          next unless child.is_a?(Element)
          process_node(child, base, lang, chain)
        end
      end

      def process_node(element, base, lang, chain)
        if xinclude_element?(element)
          if element.name == "fallback"
            raise InvalidIncludeError,
                  "xi:fallback is only allowed as a child of xi:include"
          end
          process_include(element, base, lang, chain)
        else
          process_children(element,
                           node_base(element, base),
                           element.attributes["xml:lang"] || lang,
                           chain)
        end
      end

      def process_include(include_element, base, lang, chain)
        href = include_element.attributes["href"]
        parse = include_element.attributes["parse"] || "xml"
        xpointer = include_element.attributes["xpointer"]

        unless parse == "xml" or parse == "text"
          raise InvalidIncludeError,
                "xi:include parse must be \"xml\" or \"text\", " \
                "got #{parse.inspect}"
        end
        if href and href.include?("#")
          raise InvalidIncludeError,
                "xi:include href must not contain a fragment identifier"
        end

        uri = nil
        if href and not href.empty?
          uri = resolve_uri(href, base)
          if parse == "xml" and chain.include?(uri)
            raise InclusionLoopError,
                  "xi:include loop detected for #{uri.inspect}"
          end
        elsif parse == "text"
          raise InvalidIncludeError,
                "xi:include with parse=\"text\" requires an href"
        end

        begin
          nodes = acquire(include_element, uri, parse, xpointer)
          if parse == "xml"
            nodes.each {|node| fixup(node, uri, base, lang) }
          end
          nested_base = uri || base
          nested_chain = (parse == "xml" and uri) ? chain + [uri] : chain
        rescue ResourceError => error
          fallback = include_element.elements.find do |element|
            xinclude_element?(element) and element.name == "fallback"
          end
          raise error unless fallback
          nodes = fallback.children.to_a
          nested_base = base
          nested_chain = chain
        end

        parent = include_element.parent
        nodes.each {|node| parent.insert_before(include_element, node) }
        parent.delete(include_element)

        nodes.each do |node|
          next unless node.is_a?(Element)
          process_node(node, nested_base, lang, nested_chain)
        end
      end

      # Returns an array of detached nodes not owned by any document yet.
      def acquire(include_element, uri, parse, xpointer)
        if uri.nil?
          # No href: the xpointer selects from the including document.
          unless xpointer
            raise InvalidIncludeError,
                  "xi:include without href requires an xpointer"
          end
          source = include_element.document
          return select_elements(source, xpointer).map(&:deep_clone)
        end

        content = fetch(uri)
        case parse
        when "xml"
          document = parse_document(content, uri)
          if xpointer
            select_elements(document, xpointer).map(&:deep_clone)
          else
            document.children.reject do |node|
              node.is_a?(XMLDecl) or node.is_a?(DocType)
            end.map(&:deep_clone)
          end
        when "text"
          if xpointer
            raise InvalidIncludeError,
                  "xi:include xpointer is not allowed with parse=\"text\""
          end
          [Text.new(coerce_text(content), true, nil, false)]
        end
      end

      def fetch(uri)
        begin
          content = @resolver.call(uri)
        rescue => error
          raise ResourceError,
                "failed to load #{uri.inspect}: #{error.message}"
        end
        if content.nil?
          raise ResourceError, "resource not available: #{uri.inspect}"
        end
        content = content.read if content.respond_to?(:read)
        content
      end

      def parse_document(content, uri)
        REXML::Document.new(content)
      rescue ParseException => error
        raise ResourceError,
              "failed to parse #{uri.inspect} as XML: #{error.message}"
      end

      def coerce_text(content)
        string = content.to_s
        if string.encoding == ::Encoding::ASCII_8BIT
          string.dup.force_encoding(::Encoding::UTF_8)
        elsif string.encoding != ::Encoding::UTF_8
          string.encode(::Encoding::UTF_8)
        else
          string
        end
      end

      # xml:base and xml:lang fixup for top-level included items.
      def fixup(node, resource_base, include_base, lang)
        return unless node.is_a?(Element)
        attributes = node.attributes
        if resource_base and resource_base != include_base and
           attributes["xml:base"].nil?
          attributes["xml:base"] = resource_base
        end
        if lang and attributes["xml:lang"].nil?
          attributes["xml:lang"] = lang
        end
      end

      def select_elements(document, xpointer)
        body = /\A\s*element\((.*)\)\s*\z/m.match(xpointer)
        unless body
          scheme = /\A\s*([A-Za-z][A-Za-z0-9._-]*)\s*\(/.match(xpointer)
          if scheme
            raise UnsupportedSchemeError,
                  "XPointer scheme #{scheme[1].inspect} is not supported; " \
                  "only element() is"
          end
          raise UnsupportedSchemeError,
                "unsupported XPointer #{xpointer.inspect}; " \
                "only the element() scheme is supported"
        end

        segments = body[1].split("/", -1).map(&:strip)
        if segments.first.empty?
          segments.shift
          current = document
        else
          name = segments.shift
          current = find_by_id(document, name)
          unless current
            raise ResourceError,
                  "element() found no element with ID #{name.inspect}"
          end
        end
        segments.each do |segment|
          unless segment =~ /\A[1-9]\d*\z/
            raise ResourceError,
                  "invalid element() child step #{segment.inspect}"
          end
          current = current.elements.to_a[segment.to_i - 1]
          unless current
            raise ResourceError,
                  "element() child step /#{segment} matched nothing"
          end
        end
        [current]
      end

      def find_by_id(node, id)
        if node.is_a?(Element)
          attributes = node.attributes
          return node if attributes["xml:id"] == id or attributes["id"] == id
        end
        node.each_element do |element|
          found = find_by_id(element, id)
          return found if found
        end
        nil
      end

      def xinclude_element?(element)
        element.namespace == NAMESPACE
      end

      def node_base(element, current_base)
        xml_base = element.attributes["xml:base"]
        xml_base ? resolve_uri(xml_base, current_base) : current_base
      end

      def resolve_uri(reference, base)
        combined =
          if base.nil?
            reference
          elsif base =~ /\A[A-Za-z][A-Za-z0-9+.-]*:/
            begin
              URI.join(base, reference).to_s
            rescue URI::Error => error
              raise InvalidIncludeError,
                    "invalid URI reference #{reference.inspect}: #{error.message}"
            end
          else
            merge_relative(base, reference)
          end
        normalize_uri(combined)
      end

      def merge_relative(base, reference)
        return reference if reference.start_with?("/")
        return reference if reference =~ /\A[A-Za-z][A-Za-z0-9+.-]*:/
        base_path = base.sub(/\?.*\z/, "")
        base_path.sub(%r{[^/]*\z}, "") + reference
      end

      # Canonicalizes a URI string so that different spellings of the
      # same resource compare equal: scheme and host are downcased,
      # default ports and dot segments are removed, and any fragment
      # is dropped.
      def normalize_uri(uri_string)
        uri =
          begin
            URI.parse(uri_string)
          rescue URI::Error => error
            raise InvalidIncludeError,
                  "invalid URI #{uri_string.inspect}: #{error.message}"
          end
        result = +""
        if uri.scheme
          result << uri.scheme.downcase << ":"
        end
        if uri.host
          result << "//#{uri.host.downcase}"
          if uri.port and uri.port != uri.default_port
            result << ":#{uri.port}"
          end
        end
        result << remove_dot_segments(uri.path.to_s)
        result << "?#{uri.query}" if uri.query
        result
      end

      # RFC 3986 section 5.2.4.
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
            start = input.start_with?("/") ? 1 : 0
            index = input.index("/", start) || input.length
            output << input[0...index]
            input = input[index..] || ""
          end
        end
        output
      end
    end
  end
end
