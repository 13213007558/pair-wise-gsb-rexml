# frozen_string_literal: true

require_relative "document"

module REXML
  # \Module \REXML::C14N produces Canonical XML Version 1.1
  # [https://www.w3.org/TR/xml-c14n11/] output.
  #
  # Canonical XML is a deterministic serialization: namespace
  # declarations and attributes are sorted, character references are
  # expanded, CDATA sections are replaced by their character content,
  # and a fixed set of characters is escaped.  Two documents that are
  # logically equivalent have the same canonical form, which makes it
  # suitable as the input of signature and digest algorithms.
  #
  #   document = REXML::Document.new('<root xmlns:n="u"><n:a x="1"/></root>')
  #   REXML::C14N.canonicalize(document)
  #   # => "<root xmlns:n=\"u\"><n:a x=\"1\"></n:a></root>"
  #
  # An element can be canonicalized as a document subset (a subtree).
  # The subtree root inherits the namespace declarations and the
  # xml:lang, xml:space, xml:id and xml:base attributes of its
  # ancestors as required by Canonical XML 1.1:
  #
  #   element = REXML::XPath.first(document, "//n:a")
  #   REXML::C14N.canonicalize(element, with_comments: true)
  #
  # The output is always a UTF-8 encoded String and the source tree is
  # never modified.
  #
  # Note that the canonical form reflects the tree as parsed by REXML:
  # REXML does not normalize literal whitespace characters (#x9, #xA)
  # in attribute values to spaces, so they are escaped as character
  # references instead, and REXML strips leading and trailing
  # whitespace of processing instruction data.
  module C14N
    # The namespace URI that is implicitly bound to the "xml" prefix.
    XML_NAMESPACE_URI = "http://www.w3.org/XML/1998/namespace"

    # Attributes in the XML namespace whose nearest occurrence in the
    # ancestor elements is copied to the root element of a
    # canonicalized subtree (the apex node) when the subtree root does
    # not have the attribute itself.  xml:base is not in this list
    # because ancestor xml:base values are joined instead of copied.
    XML_COPIED_ATTRIBUTES = ["xml:lang", "xml:space", "xml:id"].freeze

    class << self
      # :call-seq:
      #   REXML::C14N.canonicalize(node, with_comments: false) -> String
      #
      # Returns the Canonical XML 1.1 serialization of +node+ as a
      # UTF-8 encoded String.
      #
      # +node+ may be a REXML::Document, in which case the whole
      # document is canonicalized, or a REXML::Element, in which case
      # the subtree rooted at the element is canonicalized as a
      # document subset.  The subtree root inherits the in-scope
      # namespace declarations of its ancestors and their nearest
      # xml:lang, xml:space and xml:id attributes; ancestor xml:base
      # values are joined into the subtree root as specified by
      # Canonical XML 1.1.
      #
      # Comments are included only when +with_comments+ is true.
      #
      # The source tree is never modified.
      def canonicalize(node, with_comments: false)
        Canonicalizer.new(with_comments: with_comments).canonicalize(node)
      end
    end

    # :stopdoc:
    class Canonicalizer
      TEXT_ESCAPES = {
        "&" => "&amp;",
        "<" => "&lt;",
        ">" => "&gt;",
        "\r" => "&#xD;",
      }.freeze

      ATTRIBUTE_VALUE_ESCAPES = {
        "&" => "&amp;",
        "<" => "&lt;",
        '"' => "&quot;",
        "\t" => "&#x9;",
        "\n" => "&#xA;",
        "\r" => "&#xD;",
      }.freeze

      URI_REFERENCE_PATTERN = /\A(?:([A-Za-z][A-Za-z0-9+.\-]*):)?(?:\/\/([^\/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?\z/m

      def initialize(with_comments: false)
        @with_comments = with_comments
      end

      def canonicalize(node)
        @output = +""
        case node
        when Document
          separate = false
          node.children.each do |child|
            case child
            when Comment
              next unless @with_comments
            when Element, Instruction
            else
              next
            end
            # Top level nodes are separated by a single line feed in
            # the canonical form; whitespace text nodes outside the
            # document element are not rendered.
            emit("\n") if separate
            case child
            when Element
              write_element(child, {}, true)
            when Comment
              write_comment(child)
            when Instruction
              write_instruction(child)
            end
            separate = true
          end
        when Element
          write_element(node, {}, true)
        else
          raise ArgumentError,
                "expected REXML::Document or REXML::Element: #{node.inspect}"
        end
        @output.encode(::Encoding::UTF_8)
      end

      private

      def emit(string)
        @output << string.encode(::Encoding::UTF_8)
      end

      def write_element(element, parent_namespaces, apex)
        emit("<")
        emit(element.expanded_name)
        write_namespace_declarations(element, parent_namespaces, apex)
        write_attributes(element, apex)
        emit(">")
        element.children.each do |child|
          case child
          when Element
            write_element(child, element.namespaces, false)
          when Text
            emit(escape_text(child.value))
          when Comment
            write_comment(child) if @with_comments
          when Instruction
            write_instruction(child)
          end
        end
        emit("</")
        emit(element.expanded_name)
        emit(">")
      end

      # Renders the namespace declarations of +element+ in
      # lexicographic order of their prefixes (the default namespace
      # first).  For the subtree root (apex) every in-scope namespace
      # is rendered; for other elements only declarations that differ
      # from the namespace context of the nearest ancestor element in
      # the canonicalized node set are rendered.
      def write_namespace_declarations(element, parent_namespaces, apex)
        declarations = {}
        if apex
          element.namespaces.each do |prefix, uri|
            next if prefix == "xml" or uri.empty?
            declarations[prefix] = uri
          end
        else
          each_effective_attribute(element) do |attribute|
            next unless attribute.namespace_declaration?
            prefix = attribute.name
            next if prefix == "xml"
            uri = attribute.value
            # An empty default namespace declaration (xmlns="") is
            # only rendered when the ancestor context has a non-empty
            # default namespace; an absent declaration and an empty
            # one are the same namespace context.
            parent_uri = parent_namespaces[prefix]
            parent_uri = "" if parent_uri.nil?
            declarations[prefix] = uri if parent_uri != uri
          end
        end
        declarations.sort_by {|prefix, _| namespace_sort_key(prefix)}.each do |prefix, uri|
          emit(" ")
          emit(prefix == "xmlns" ? "xmlns" : "xmlns:#{prefix}")
          emit("=\"")
          emit(escape_attribute_value(uri))
          emit("\"")
        end
      end

      def namespace_sort_key(prefix)
        prefix == "xmlns" ? "" : prefix
      end

      # Renders the attributes of +element+, sorted by namespace URI
      # and then by local name (attributes in no namespace first).
      def write_attributes(element, apex)
        attributes = []
        each_effective_attribute(element) do |attribute|
          next if attribute.namespace_declaration?
          attributes << [attribute_namespace_uri(element, attribute),
                         attribute.name,
                         attribute.expanded_name,
                         attribute.value]
        end
        inherit_xml_attributes(element, attributes) if apex
        attributes.sort_by {|uri, local_name, _, _| [uri, local_name]}.each do |_, _, name, value|
          emit(" ")
          emit(name)
          emit("=\"")
          emit(escape_attribute_value(value))
          emit("\"")
        end
      end

      def attribute_namespace_uri(element, attribute)
        case attribute.prefix
        when ""
          ""
        when "xml"
          XML_NAMESPACE_URI
        else
          element.namespace(attribute.prefix) || ""
        end
      end

      # Canonical XML 1.1, 2.4 Document Subsets: the root element of a
      # canonicalized subtree inherits the nearest xml:lang, xml:space
      # and xml:id attributes of its ancestors, and the joined xml:base
      # values of its ancestors.
      def inherit_xml_attributes(element, attributes)
        own = effective_attribute_map(element)
        ancestors = []
        ancestor = element.parent
        while ancestor.is_a?(Element)
          ancestors.unshift(ancestor)
          ancestor = ancestor.parent
        end
        inherited = {}
        ancestors.reverse_each do |ancestor_element|
          effective_attribute_map(ancestor_element).each do |name, value|
            inherited[name] = value unless inherited.key?(name)
          end
        end
        XML_COPIED_ATTRIBUTES.each do |name|
          next if own.key?(name)
          value = inherited[name]
          next if value.nil?
          attributes << [XML_NAMESPACE_URI, name.delete_prefix("xml:"), name, value]
        end
        bases = ancestors.filter_map {|a| effective_attribute_map(a)["xml:base"]}
        if own.key?("xml:base")
          joined = join_xml_base_values(bases + [own["xml:base"]])
          attributes.each do |entry|
            entry[3] = joined if entry[2] == "xml:base"
          end
        elsif not bases.empty?
          attributes << [XML_NAMESPACE_URI, "base", "xml:base", join_xml_base_values(bases)]
        end
      end

      # Joins xml:base values from the outermost to the innermost as
      # specified by Canonical XML 1.1, 2.4 Document Subsets.
      def join_xml_base_values(values)
        values.reduce("") {|base, reference| join_xml_base(base, reference)}
      end

      def join_xml_base(base, reference)
        return base if reference.empty?
        return reference if base.empty?
        # A same-document reference is concatenated with the base
        # instead of being resolved against it.
        return base + reference if reference.start_with?("#")
        return reference if /\A[A-Za-z][A-Za-z0-9+.\-]*:/.match?(reference)
        resolve_uri_reference(base, reference)
      end

      # Resolves +reference+ against +base+ as described in RFC 3986,
      # 5.2.2 Transform References.
      def resolve_uri_reference(base, reference)
        base_match = URI_REFERENCE_PATTERN.match(base)
        reference_match = URI_REFERENCE_PATTERN.match(reference)
        scheme = base_match[1]
        authority = base_match[2]
        path = base_match[3]
        query = base_match[4]
        if reference_match[2]
          authority = reference_match[2]
          path = remove_dot_segments(reference_match[3])
          query = reference_match[4]
        elsif reference_match[3].empty?
          query = reference_match[4] || query
        else
          if reference_match[3].start_with?("/")
            path = remove_dot_segments(reference_match[3])
          else
            merged = if authority and path.empty?
                       "/#{reference_match[3]}"
                     else
                       path.sub(%r{[^/]*\z}, "") + reference_match[3]
                     end
            path = remove_dot_segments(merged)
          end
          query = reference_match[4]
        end
        result = +""
        result << "#{scheme}:" if scheme
        result << "//#{authority}" if authority
        result << path
        result << "?#{query}" if query
        fragment = reference_match[5]
        result << "##{fragment}" if fragment
        result
      end

      # RFC 3986, 5.2.4 Remove Dot Segments.
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
            output = output.sub(%r{/?[^/]*\z}, "")
          elsif input == "/.."
            input = "/"
            output = output.sub(%r{/?[^/]*\z}, "")
          elsif input == "." or input == ".."
            input = ""
          else
            segment = input[%r{\A/?[^/]*}]
            output << segment
            input = input[segment.length..]
          end
        end
        output
      end

      def write_comment(comment)
        emit("<!--")
        emit(comment.string.to_s.gsub("\r", "&#xD;"))
        emit("-->")
      end

      def write_instruction(instruction)
        emit("<?")
        emit(instruction.target)
        content = instruction.content
        if content and not content.empty?
          emit(" ")
          emit(content.gsub("\r", "&#xD;"))
        end
        emit("?>")
      end

      def escape_text(string)
        string.gsub(/[&<>\r]/, TEXT_ESCAPES)
      end

      def escape_attribute_value(string)
        string.gsub(/[&<"\t\n\r]/, ATTRIBUTE_VALUE_ESCAPES)
      end

      # Iterates over the attributes of +element+ including the
      # attributes defaulted by the DTD, which are part of the XPath
      # data model that Canonical XML is defined on.
      def each_effective_attribute(element, &block)
        element.attributes.send(:each_effective_attribute).each(&block)
      end

      def effective_attribute_map(element)
        map = {}
        each_effective_attribute(element) do |attribute|
          map[attribute.expanded_name] = attribute.value
        end
        map
      end
    end
    # :startdoc:
  end
end
