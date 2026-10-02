# frozen_string_literal: false

require_relative "document"
require "uri"

module REXML
  # XInclude 1.0 processing for REXML.
  #
  # This module processes +<xi:include>+ elements as described by
  # {XInclude Version 1.0 (Second Edition)}[https://www.w3.org/TR/xinclude/],
  # using the namespace +http://www.w3.org/2001/XInclude+.
  #
  # Both +parse="xml"+ (the default) and +parse="text"+ inclusions are
  # supported, including +<xi:fallback>+ content, nested includes and the
  # base URI and language fixups. This first version does not implement
  # XPointer: an +xpointer+ attribute or a fragment identifier on +href+
  # is rejected as a fatal error.
  #
  # Resources are never fetched over the network by the default resolver;
  # the default resolver reads +file:+ URIs only. Callers supply a resolver
  # to read resources from any other location.
  #
  # == Example
  #
  #   require 'rexml/xinclude'
  #
  #   doc = REXML::Document.new(File.read('main.xml'))
  #   REXML::XInclude.process(doc, base_uri: 'file:///tmp/main.xml')
  #   # or:
  #   doc.xinclude(base_uri: 'file:///tmp/main.xml')
  #
  # == Resolvers
  #
  # A resolver is any object responding to one of:
  #
  # - #call(uri, context): the resolved URI (a URI object) and a context
  #   Hash containing +:uri+, +:base_uri+, +:parse+, +:encoding+,
  #   +:accept+ and +:accept_language+;
  # - #call(uri): just the resolved URI.
  #
  # It must return the resource content as a String. Raising an exception
  # (for example REXML::XInclude::ResourceError) makes the processor use the
  # +<xi:fallback>+ child element when one is present.
  module XInclude
    # The XInclude 1.0 namespace URI.
    NAMESPACE = "http://www.w3.org/2001/XInclude".freeze

   # The predefined +xml+ namespace URI.
    XML_NAMESPACE = "http://www.w3.org/XML/1998/namespace".freeze

   URI_PARSER = defined?(URI::RFC2396_PARSER) ? URI::RFC2396_PARSER : URI::DEFAULT_PARSER

    # Base class for errors raised while processing XInclude directives.
    class Error < StandardError
    end

    # A fatal error that cannot be recovered with +<xi:fallback>+.
    class FatalError < Error
    end

    # An include loop was detected. +chain+ contains the complete URI chain
    # (including the URI that closes the loop).
    class LoopError < FatalError
      # The Array of URI objects forming the include chain.
      attr_reader :chain

      def initialize(chain)
        @chain = chain
        super("XInclude loop detected: " + chain.collect(&:to_s).join(" -> "))
      end
    end

    # The referenced resource could not be fetched or decoded. Recoverable
    # through a +<xi:fallback>+ element.
    class ResourceError < Error
    end

    # The referenced resource could not be parsed as XML. Recoverable
    # through a +<xi:fallback>+ element.
    class ParseError < ResourceError
    end

    # A +parse="text"+ resource could not be decoded. Recoverable through
    # a +<xi:fallback>+ element.
    class EncodingError < ResourceError
    end

    # XPointer and fragment identifiers are not supported by this version.
    class UnsupportedXPointerError < FatalError
    end

    # Default resolver: reads +file:+ URIs from the local file system.
    #
    # Every other URI scheme raises REXML::XInclude::ResourceError, so no
    # network access is performed unless the caller provides a resolver.
    class FileResolver
      # Returns the content of +uri+ as a binary encoded String.
      def call(uri, context = nil)
        unless uri.is_a?(URI::File)
          message = "unsupported URI scheme for #{uri} " "(only file: URIs are fetched by the default resolver)"
          raise ResourceError.new(message)
        end
        path = URI_PARSER.unescape(uri.path)
        begin
          File.binread(path)
        rescue SystemCallError => error
          raise ResourceError.new("unable to read #{uri}: #{error.message}")
        end
      end
    end

    # Processes all XInclude directives in +node+ (a REXML::Document or
    # REXML::Element). Returns +node+.
    #
    # Options:
    #
    # - +:resolver+ - callable used to fetch resources (defaults to a
    #   REXML::XInclude::FileResolver);
    # - +:base_uri+ - base URI of +node+ (String or URI). Relative +href+
    #   values are resolved against it. When omitted, the document context
    #   entry +:base_uri+ is used when present; otherwise the current
    #   working directory is used;
    # - +:document_base_uri+ - alias for +:base_uri+.
    def self.process(node, resolver: nil, base_uri: nil, document_base_uri: nil)
      base_uri ||= document_base_uri
      processor = Processor.new(resolver || FileResolver.new, base_uri)
      processor.run(node)
      node
    end

    class Processor # :nodoc: all
      UNICODE_BOM = {
        "\xFE\xFF".b => ::Encoding::UTF_16BE,
        "\xFF\xFE".b => ::Encoding::UTF_16LE,
        "\xEF\xBB\xBF".b => ::Encoding::UTF_8,
      }.freeze

      ENCODING_ALIASES = {
        "utf-16" => ::Encoding::UTF_16,
        "utf-8" => ::Encoding::UTF_8,
      }.freeze

      def initialize(resolver, base_uri)
        @resolver = resolver
        @base_uri_option = base_uri
        @cache = {}
      end

      def run(node)
        document = node.is_a?(Document) ? node : node.document
        base = document_base(document, @base_uri_option)
        process_scope(node, [], base)
      end

      private

      # -- tree walking --------------------------------------------------

      def xinclude_element?(node, local_name)
        node.is_a?(Element) &&
          node.name == local_name &&
          node.namespace(node.prefix) == NAMESPACE
      end

      def include_element?(node)
        xinclude_element?(node, "include")
      end

      def fallback_element?(node)
        xinclude_element?(node, "fallback")
      end

      # Walks the children of +container+. +chain+ is the include chain
      # that applies to include directives in this scope (it already
      # includes the URI of the resource being walked, or the failed URI of
      # a surrounding fallback); +base+ is the base URI against which
      # references in this scope resolve.
      def process_scope(container, chain, base)
        index = 0
        while index < container.children.length
          node = container.children[index]
          if include_element?(node)
            walk_base, next_chain, replacements =
              process_include(node, chain, base)
            splice(container, index, node, replacements)
            # Process the spliced content under its own scope. Included
            # content resolves against the included URI and extends the
            # chain; fallback content keeps the current scope's base URI
            # (process_include reports it as +base+) while the failed URI is
            # still present in the chain.
            process_scope_children(container, index, index + replacements.length,
                                  next_chain, walk_base)
            index += replacements.length
          elsif node.is_a?(Parent)
            process_scope(node, chain, base)
            index += 1
          else
            index += 1
          end
        end
      end

      # Processes children of +container+ in the given range under a new
      # scope, resolving any include directive (including one spliced in
      # directly, as happens with nested includes inside fallback content).
      def process_scope_children(container, from, to, chain, base)
        index = from
        while index < to && index < container.children.length
          node = container.children[index]
          if include_element?(node)
            walk_base, next_chain, replacements = process_include(node, chain, base)
            splice(container, index, node, replacements)
            to += replacements.length - 1
            process_scope_children(container, index, index + replacements.length,
                                  next_chain, walk_base)
            index += replacements.length
          elsif node.is_a?(Parent)
            process_scope(node, chain, base)
            index += 1
          else
            index += 1
          end
        end
      end

      def splice(container, index, include_node, replacements)
        children = container.instance_variable_get(:@children)
        children[index, 1] = replacements
        include_node.instance_variable_set(:@parent, nil)
        replacements.each { |child| child.parent = container }
      end

      # -- single include directive -------------------------------------

      def process_include(include, chain, base)
        validate_include_children(include)
        attributes = validate_include_attributes(include)
        href = attributes["href"]
        parse = attributes["parse"] || "xml"

        if attributes["xpointer"]
          raise UnsupportedXPointerError.new(
            "xpointer is not supported: #{attributes['xpointer'].inspect}")
        end
        unless href && !href.empty?
          raise FatalError.new("xi:include requires a non-empty href")
        end

        include_base = effective_base(include, base)
        target = join_uri(include_base, href)
        unless target.fragment.nil?
          raise UnsupportedXPointerError.new(
            "XPointer fragment identifiers are not supported: #{target}")
        end

        extended_chain = chain + [target]
        if chain.include?(target)
          raise LoopError.new(extended_chain)
        end

        language = in_scope_language(include)
        context = {
          uri: target,
          base_uri: include_base,
          parse: parse,
          encoding: attributes["encoding"],
          accept: attributes["accept"],
          accept_language: attributes["accept-language"],
        }

        begin
          content = fetch(target, context)
          if parse == "text"
            text = build_text(content, attributes["encoding"])
            [target, extended_chain, [Text.new(text, true)]]
          else
            [target, extended_chain, build_xml(content, target, language, include)]
          end
        rescue UnsupportedXPointerError, FatalError
          raise
        rescue ResourceError
          children = perform_fallback(include)
          raise if children.nil?
          # Fallback content belongs to the including document, so nested
          # references resolve against the incoming base URI; the failed
          # URI still participates in loop detection.
          [base, extended_chain, children]
        end
      end

      def perform_fallback(include)
        fallback = include.children.find { |child| fallback_element?(child) }
        return nil unless fallback
        validate_fallback_children(fallback)
        # Detach the fallback's content; it is spliced in place and walked by
        # the caller.
        children = fallback.children.dup
        children.each do |child|
          fallback.children.delete(child)
          child.parent = nil
        end
        children
      end

      def validate_include_children(include)
        fallbacks = 0
        include.children.each do |child|
          if fallback_element?(child)
            fallbacks += 1
          elsif child.is_a?(Element) && child.namespace(child.prefix) == NAMESPACE
            raise FatalError.new(
              "unexpected <#{child.fully_expanded_name}> in XInclude namespace ""inside xi:include")
          elsif child.is_a?(Text) && !child.value.strip.empty?
            raise FatalError.new("non-whitespace content inside xi:include")
          end
        end
        if fallbacks > 1
          raise FatalError.new("xi:include has #{fallbacks} xi:fallback children ""(at most one is allowed)")
        end
      end

      def validate_include_attributes(include)
        allowed = %w[href parse xpointer encoding accept accept-language]
        result = {}
        include.attributes.each_attribute do |attribute|
          local = attribute.name
          if attribute.namespace == NAMESPACE && !allowed.include?(local)
            raise FatalError.new(
              "unknown XInclude attribute #{attribute.expanded_name.inspect}")
          end
          if allowed.include?(local) && attribute.namespace.empty?
            result[local] = attribute.value
          end
        end
        parse = result["parse"]
        if parse && parse != "xml" && parse != "text"
          raise FatalError.new("invalid xi:include parse value: #{parse.inspect}")
        end
        result
      end

      def validate_fallback_children(fallback)
        fallback.children.each do |child|
          if fallback_element?(child)
            raise FatalError.new("xi:fallback cannot be nested")
          end
        end
      end

      # -- resource fetching -------------------------------------------

      def fetch(uri, context)
        key = uri.to_s
        return @cache[key] if @cache.key?(key)
        content = invoke_resolver(uri, context)
        unless content.is_a?(String)
          raise ResourceError.new("resolver returned #{content.class} for #{uri} " "(expected String)")
        end
        @cache[key] = content.b
      end

      def invoke_resolver(uri, context)
        if @resolver.respond_to?(:call)
          begin
            return @resolver.call(uri, context)
          rescue ArgumentError
            begin
              return @resolver.call(uri)
            rescue REXML::XInclude::Error
              raise
            rescue => error
              raise ResourceError.new("failed to fetch #{uri}: #{error.message}")
            end
          end
        end
        raise ResourceError.new("resolver does not respond to #call")
      rescue REXML::XInclude::Error
        raise
      rescue => error
        raise ResourceError.new("failed to fetch #{uri}: #{error.message}")
      end

      # -- parse="text" -------------------------------------------------

      def build_text(raw_content, encoding_name)
        raw = raw_content.b.dup
        bom_encoding = detect_bom(raw)
        encoding = nil

        if encoding_name
          encoding = find_encoding(encoding_name) ||
            raise(EncodingError.new("unknown encoding #{encoding_name.inspect}"))
        end

        if bom_encoding
          if encoding && encoding != bom_encoding &&
             !(encoding == ::Encoding::UTF_16 && bom_encoding.name.start_with?("UTF-16"))
            raise EncodingError.new(
              "encoding #{encoding.name} conflicts with byte order mark " "indicating #{bom_encoding.name}")
          end
          encoding = bom_encoding unless encoding == ::Encoding::UTF_16
        end

        encoding ||= ::Encoding::UTF_8
        begin
          decoded = raw.force_encoding(encoding)
          unless decoded.valid_encoding?
            raise EncodingError.new("included text is not valid #{encoding.name}")
          end
          decoded = decoded.encode(::Encoding::UTF_8)
        rescue ::Encoding::UndefinedConversionError, ::Encoding::InvalidByteSequenceError => error
          raise EncodingError.new("failed to decode included text as #{encoding.name}: " "#{error.message}")
        end
        strip_bom(decoded)
      end

      def detect_bom(raw)
        UNICODE_BOM.each do |bytes, encoding|
          return encoding if raw.start_with?(bytes)
        end
        nil
      end

      def find_encoding(name)
        key = name.to_s.downcase
        if ENCODING_ALIASES.key?(key)
          ENCODING_ALIASES[key]
        else
          begin
            ::Encoding.find(name)
          rescue ArgumentError
            nil
          end
        end
      end

      def strip_bom(string)
        bom = "\uFEFF"
        string.start_with?(bom) ? string.sub(/\A#{bom}/, "") : string
      end

      # -- parse="xml" --------------------------------------------------

      def build_xml(content, target, language, include = nil)
        document, fragment_content = parse_xml(content, target, include)
        if document
          items = document.children.select do |child|
            child.is_a?(Element) || child.is_a?(Comment) || child.is_a?(Instruction)
          end
        else
          fragment_root = fragment_content
          items = fragment_root.children.dup
        end
        items.each do |item|
          next unless item.is_a?(Element)
          apply_base_fixup(item, target)
          apply_language_fixup(item, language)
        end
        items
      end

      # Returns [document, nil] for a well-formed document or
      # [nil, fragment_content] for content that must be parsed as a
      # general parsed entity (fragment).
      def parse_xml(content, target, include)
        stripped = strip_xml_declaration(content.b)
        begin
          document = Document.new(content.b, {})
        rescue REXML::ParseException => error
          if error.message.include?("Extra tag at the end of the document")
            fragment_root = parse_xml_fragment(stripped, target, include)
            return [nil, fragment_root]
          end
          raise ParseError.new("failed to parse XML resource #{target}: ""#{error.message}")
        end
        roots = document.children.count { |child| child.is_a?(Element) }
        if roots == 1
          [document, nil]
        else
          # More than one root element without an "extra tag" error: treat
          # the content as a general parsed entity (fragment).
          fragment_root = parse_xml_fragment(stripped, target, include)
          [nil, fragment_root]
        end
      end

      def parse_xml_fragment(stripped, target, include)
        namespaces = fragment_namespace_declarations(include)
        wrapped = "<#{FRAGMENT_ROOT}#{namespaces}>""#{stripped}""</#{FRAGMENT_ROOT}>"
        begin
          document = Document.new(wrapped, {})
        rescue REXML::ParseException => error
          raise ParseError.new("failed to parse XML resource #{target}: ""#{error.message}")
        rescue => error
          raise ParseError.new("failed to parse XML fragment #{target}: ""#{error.message}")
        end
        fragment_root = document.root
        unless fragment_root
          raise ParseError.new("failed to parse XML fragment #{target}")
        end
        fragment_root
      end

      FRAGMENT_ROOT = "__rexml_xinclude_fragment__".freeze

      def strip_xml_declaration(content)
        stripped = content.sub(/\A\uFEFF/, "")
        stripped.sub(/\A<\?xml\s.*?\?>/m, "")
      end

      def fragment_namespace_declarations(include)
        return "" unless include
        declarations = []
        include.namespaces.each do |prefix, uri|
          next if prefix == "xml"
          name = prefix == "xmlns" || prefix.nil? || prefix.empty? ? "xmlns" : "xmlns:#{prefix}"
          declarations << " #{name}=" + '"' + escape_attribute(uri) + '"'
        end
        declarations.join("")
      end

      def escape_attribute(value)
        value.to_s.gsub('&', '&amp;').gsub('"', '&quot;')
      end

      # -- base URI and language fixup ---------------------------------

      def apply_base_fixup(element, target)
        existing = xml_attribute(element, "base")
        base_uri = if existing && !existing.value.strip.empty?
          begin
            join_uri(target, existing.value)
          rescue ResourceError
            target
          end
        else
          target
        end
        element.add_attribute("xml:base", base_uri.to_s)
      end

      def apply_language_fixup(element, language)
        return if language.nil? || language.empty?
        existing = xml_attribute(element, "lang")
        element.add_attribute("xml:lang", language) if existing.nil?
      end

      def xml_attribute(element, local_name)
        element.attributes.each_attribute do |attribute|
          if attribute.name == local_name &&
             (attribute.namespace.nil? || attribute.namespace.empty? ||
              attribute.namespace == XML_NAMESPACE)
            return attribute
          end
        end
        nil
      end

      # The language in scope for +element+ itself, i.e. its own xml:lang
      # or one inherited from an ancestor.
      def in_scope_language(element)
        node = element
        while node
          attribute = node.is_a?(Element) ? xml_attribute(node, "lang") : nil
          return attribute.value if attribute
          node = node.parent
        end
        nil
      end

      # -- base URIs ----------------------------------------------------

      def document_base(document, option)
        coerce_uri(option) ||
          (document && document.context[:base_uri] && coerce_uri(document.context[:base_uri])) ||
          cwd_uri
      end

      # Computes the effective base URI of +include+, taking xml:base
      # attributes on ancestors into account.
      def effective_base(include, fallback_base)
        values = []
        node = include
        while node && node.is_a?(Element)
          attribute = xml_attribute(node, "base")
          values << attribute.value if attribute && !attribute.value.strip.empty?
          node = node.parent
        end
        base = fallback_base
        values.reverse_each do |value|
          base = join_uri(base, value)
        end
        base
      end

      def join_uri(base, reference)
        URI.join(base, reference)
      rescue URI::InvalidURIError, URI::InvalidComponentError, ArgumentError => error
        raise ResourceError.new("invalid URI reference #{reference.inspect} " "relative to #{base}: #{error.message}")
      end

      def coerce_uri(value)
        return nil if value.nil?
        return value if value.is_a?(URI::Generic)
        begin
          uri = URI.parse(value.to_s)
        rescue URI::InvalidURIError => error
          raise FatalError.new("invalid base URI #{value.inspect}: #{error.message}")
        end
        if uri.scheme.nil?
          file_uri(File.expand_path(value.to_s))
        else
          uri
        end
      end

      def cwd_uri
        file_uri(Dir.pwd + File::SEPARATOR)
      end

     def file_uri(path)
        escaped = URI_PARSER.escape(path)
        escaped = escaped.sub(/\A\//, "")
        URI.parse("file://" + "/" + escaped)
     end
    end
  end

  class Document
    # Processes XInclude directives in this document.
    # See REXML::XInclude.process for options.
    def xinclude(resolver: nil, base_uri: nil, document_base_uri: nil)
      REXML::XInclude.process(self,
                             resolver: resolver,
                             base_uri: base_uri || document_base_uri)
    end
  end
end
