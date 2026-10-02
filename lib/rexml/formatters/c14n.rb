# frozen_string_literal: false

require_relative "default"
require "set"

module REXML
  module Formatters
    # Canonical XML 1.1 output.
    class CanonicalXML11 < Default
      XML_NAMESPACE_PREFIX = "xml"
      XML_NAMESPACE_URI = "http://www.w3.org/XML/1998/namespace"
      INHERITED_ATTRIBUTES = %w[xml:lang xml:space xml:base].freeze

      State = Struct.new(:active_namespaces, :declared_namespaces, :inherited_namespaces,
                        :visible_namespace_prefixes, :base_uri,
                        :synthetic_attributes, :synthetic_namespaces, :root,
                        :undeclare_default, :root_parent_namespaces,
                        keyword_init: true)

      # Creates a formatter for Canonical XML 1.1.
      #
      # +include_comments+ controls whether comment nodes are emitted.
      def initialize(include_comments = true)
        super()
        @include_comments = include_comments
      end

      def write(node, output = +"")
        case node
        when Document
          write_document(node, output)
        when Element
          write_subtree(node, output)
        else
          super
        end
        output
      end

      protected

      def write_document(node, output)
        node.children.each do |child|
          case child
          when Element
            state = initial_state(child)
            write_element(child, output, state)
          when Instruction
            write_instruction(child, output)
          when Comment
            write_comment(child, output) if @include_comments
          end
        end
      end

      def write_subtree(element, output)
        state = subtree_state(element)
        write_element(element, output, state)
      end

      def write_element(element, output, state)
        output << "<" << element.expanded_name
        write_attributes(element, output, state)
        children = element.children
        if children.empty?
          output << "></" << element.expanded_name << ">"
          return
        end

        output << ">"
        children.each { |child| write_node(child, output, state) }
        output << "</" << element.expanded_name << ">"
      end

      def write_node(node, output, parent_state)
        case node
        when Element
          child = child_state(node, parent_state)
          write_element(node, output, child)
        when Text, CData
          write_text(node, output)
        when Comment
          write_comment(node, output) if @include_comments
        when Instruction
          write_instruction(node, output)
        end
      end

      def write_text(node, output)
        value = node.kind_of?(Text) && node.raw && !node.kind_of?(CData) ?
          canonical_raw_text_value(node) : node.value
        output << canonical_text(value)
      end

      def canonical_raw_text_value(node)
        value = node.value
        return value unless value.include?("\r") &&
                              node.to_s.match?(/&#0*(?:13|x[dD]);/)
        preserve_carriage_return_references(node.to_s, node.doctype)
      end

      def write_comment(node, output)
        output << Comment::START << normalize_line_endings(node.to_s) << Comment::STOP
      end

      def write_instruction(node, output)
        output << Instruction::START << node.target
        output << " " << normalize_line_endings(node.content) unless node.content.nil?
        output << Instruction::STOP
      end

      def normalize_line_endings(value)
        value.gsub(/\r\n?/, "\n")
      end

      def write_attributes(element, output, state)
        all_attributes = effective_attributes(element)
        namespace_attributes = all_attributes.select(&:namespace_declaration?)
        regular_attributes = all_attributes.reject(&:namespace_declaration?)
        if state.synthetic_attributes
          regular_attributes = regular_attributes.map do |attribute|
            next attribute unless attribute.expanded_name == "xml:base" && state.base_uri
            resolved = resolve_base_uri(attribute.value, state.base_uri)
            Attribute.new(attribute.expanded_name,
                          Text.normalize(resolved, element.document&.doctype),
                          element)
          end
        end

        regular_attributes.concat(inherited_attributes(element, state))

        namespace_attributes = canonical_namespaces(element,
                                                     namespace_attributes,
                                                     state)
        namespace_attributes.each do |prefix, uri|
          write_attribute(prefix.empty? ? "xmlns" : "xmlns:#{prefix}",
                          uri, output, +"")
        end

        regular_attributes.sort_by do |attribute|
          [attribute.namespace || +"", attribute.name, attribute.expanded_name]
        end.each do |attribute|
          value = canonical_attribute_value(attribute)
          write_attribute(attribute.expanded_name, value, output, +"")
        end
      end

      def write_attribute(name, value, output, _ignored)
        output << " " << name << "=\"" << canonical_attribute(value) << "\""
      end

      def canonical_text(value)
        escape(value, true)
      end

      def canonical_attribute(value)
        escape(value, false)
      end

      def canonical_attribute_value(attribute)
        value = attribute.value
        return value unless value.include?("\r") &&
                              attribute.to_s.match?(/&#0*(?:13|x[dD]);/)
        preserve_carriage_return_references(attribute.to_s, attribute.doctype)
      end

      def preserve_carriage_return_references(source, doctype)
        preserved = +""
        position = 0
        source.scan(Text::REFERENCE) do
          match = Regexp.last_match
          preserved << source[position...match.begin(0)].gsub(/\r\n?/, "\n")
          preserved << match[0]
          position = match.end(0)
        end
        preserved << source[position..-1].gsub(/\r\n?/, "\n")
        preserved.gsub(Text::REFERENCE) do |reference|
          Text.expand(reference, doctype, nil)
        end
      end

      def escape(value, text_node)
        pattern = text_node ? /[&<>\r]/ : /[&<"\t\n\r]/
        value.gsub(pattern, text_node ? ENTITY_MAP_FOR_TEXT : ENTITY_MAP_FOR_ATTRIBUTES)
      end

      ENTITY_MAP_FOR_TEXT = {
        "&" => "&amp;",
        "<" => "&lt;",
        ">" => "&gt;",
        "\r" => "&#xD;"
      }.freeze

      ENTITY_MAP_FOR_ATTRIBUTES = {
        "&" => "&amp;",
        "<" => "&lt;",
        "\"" => "&quot;",
        "\t" => "&#x9;",
        "\n" => "&#xA;",
        "\r" => "&#xD;"
      }.freeze

      private

      def initial_state(element)
        active = in_scope_namespaces(element)
        rendered = {}
        local_namespace_declarations(element).each do |prefix, uri|
          rendered[prefix] = uri if active[prefix] == uri
        end
        State.new(active_namespaces: active,
                  declared_namespaces: rendered,
                  inherited_namespaces: {},
                  visible_namespace_prefixes: visible_namespace_prefixes(element),
                  base_uri: inherited_base_uri(element.parent),
                  synthetic_attributes: false,
                  synthetic_namespaces: false,
                  root: true,
                  undeclare_default: false,
                  root_parent_namespaces: {})
      end

      def subtree_state(element)
        active = in_scope_namespaces(element)
        visible = visible_namespace_prefixes(element)
        rendered = {}
        local = local_namespace_declarations(element)
        parent_namespaces = inherited_active_namespaces(element)
        active.each do |prefix, uri|
          next if prefix == XML_NAMESPACE_PREFIX
          next if uri.empty?
          next unless local.key?(prefix) ||
                        visible.include?(prefix) ||
                        parent_namespaces.key?(prefix)
          rendered[prefix] = uri
        end
        parent_namespaces.each do |prefix, uri|
          next if prefix == XML_NAMESPACE_PREFIX || uri.empty? || local.key?(prefix)
          rendered[prefix] = uri
        end
        rendered.merge!(local) do |_prefix, local_uri, _active_uri|
          local_uri
        end
        rendered.delete("") if local[""]&.empty?
        State.new(active_namespaces: active,
                  declared_namespaces: rendered,
                  inherited_namespaces: {},
                  visible_namespace_prefixes: visible,
                  base_uri: inherited_base_uri(element.parent),
                  synthetic_attributes: true,
                  synthetic_namespaces: true,
                  root: true,
                  undeclare_default: false,
                  root_parent_namespaces: parent_namespaces)
      end

      def locally_visible_namespace_prefixes(element)
        prefixes = Set.new
        add_visible_prefix(prefixes, element.expanded_name)
        prefixes
      end

      def child_state(element, parent_state)
        local = local_namespace_declarations(element)
        active = parent_state.active_namespaces.merge(local)
        visible = parent_state.visible_namespace_prefixes
        inherited = parent_state.declared_namespaces.dup
        declared = inherited.merge(local)
        State.new(active_namespaces: active,
                  declared_namespaces: declared,
                  inherited_namespaces: inherited,
                  visible_namespace_prefixes: visible,
                  base_uri: effective_base_uri(element, parent_state.base_uri),
                  synthetic_attributes: false,
                  synthetic_namespaces: false,
                  root: false,
                  undeclare_default: parent_state.synthetic_namespaces,
                  root_parent_namespaces: parent_state.root_parent_namespaces)
      end

      def canonical_namespaces(element, attributes, state)
        local = {}
        attributes.each do |attribute|
          local[namespace_prefix(attribute)] = attribute.value
        end

        result = {}
        state.active_namespaces.each do |prefix, uri|
          next if prefix == XML_NAMESPACE_PREFIX
          if state.synthetic_namespaces
            next unless state.declared_namespaces[prefix] == uri
          elsif state.root
            next unless local[prefix] == uri
          elsif !state.root && local[prefix] == uri
            next unless !state.inherited_namespaces.key?(prefix) ||
                          state.inherited_namespaces[prefix] != uri
          else
            next
          end
          result[prefix] = uri
        end
        if state.undeclare_default &&
           state.declared_namespaces.key?("") &&
           state.active_namespaces[""] &&
           !state.active_namespaces[""].empty? &&
           element.prefix.empty?
          result[""] = +""
        end
        result.sort
      end

      def effective_attributes(element)
        attributes = element.attributes.to_a
        doctype = element.document&.doctype
        if doctype
          names = attributes.map(&:expanded_name)
          mappings = doctype._attlist_mappings[element.expanded_name] || {}
          mappings.each do |name, value|
            next if names.include?(name)
            attributes << Attribute.new(name, value, element)
          end
        end
        attributes
      end

      def local_namespace_declarations(element)
        effective_attributes(element).select(&:namespace_declaration?).each_with_object({}) do |attribute, namespaces|
          prefix = namespace_prefix(attribute)
          namespaces[prefix] = attribute.value
        end
      end

      def namespace_prefix(attribute)
        attribute.prefix.empty? ? +"" : attribute.name
      end

      def in_scope_namespaces(element)
        namespaces = element.namespaces.each_with_object({}) do |(prefix, uri), result|
          result[prefix == "xmlns" ? +"" : prefix.dup] = uri
        end
        namespaces[XML_NAMESPACE_PREFIX] = XML_NAMESPACE_URI
        namespaces
      end

      def inherited_active_namespaces(element)
        parent = element.parent
        parent.is_a?(Element) ? in_scope_namespaces(parent) : {}
      end

      def visible_namespace_prefixes(element, prefixes = nil)
        prefixes ||= Set.new
        add_visible_prefix(prefixes, element.expanded_name)
        effective_attributes(element).each do |attribute|
          next if attribute.namespace_declaration?
          add_visible_prefix(prefixes, attribute.expanded_name) unless attribute.prefix.empty?
        end
        element.children.each do |child|
          visible_namespace_prefixes(child, prefixes) if child.kind_of?(Element)
        end
        prefixes
      end

      def add_visible_prefix(prefixes, expanded_name)
        if expanded_name.include?(":")
          prefix = expanded_name.split(":", 2).first
          prefixes << prefix unless prefix == XML_NAMESPACE_PREFIX
        else
          prefixes << +""
        end
      end

      def inherited_attributes(element, state)
        return [] unless state.synthetic_attributes
        INHERITED_ATTRIBUTES.each_with_object([]) do |name, result|
          next if effective_attribute?(element, name)
          value = inherited_attribute(element.parent, name)
          next if value.nil?

          value = state.base_uri if name == "xml:base"
          result << Attribute.new(name,
                                 Text.normalize(value, element.document&.doctype),
                                 element)
        end
      end

      def effective_attribute?(element, name)
        element.attributes.get_attribute(name)
      end

      def inherited_attribute(element, name)
        while element && !element.kind_of?(Document)
          attribute = element.attributes.get_attribute(name)
          return attribute.value if attribute
          element = element.parent
        end
        nil
      end

      def inherited_base_uri(element)
        base = nil
        ancestors(element).reverse_each do |ancestor|
          attribute = ancestor.attributes.get_attribute("xml:base")
          next unless attribute
          base = base ? resolve_base_uri(attribute.value, base) : attribute.value
        end
        base
      end

      def effective_base_uri(element, parent_base_uri)
        attribute = element.attributes.get_attribute("xml:base")
        return parent_base_uri if attribute.nil?
        parent_base_uri.nil? ? attribute.value :
          resolve_base_uri(attribute.value, parent_base_uri)
      end

      def ancestors(element)
        ancestors = []
        while element && !element.kind_of?(Document)
          ancestors << element
          element = element.parent
        end
        ancestors
      end

      def resolve_base_uri(reference, base)
        return reference if base.nil?
        merge_uri_references(base, reference)
      end

      URI_REGEXP = /\A(?:([^:\/?#]+):)?(?:\/\/([^\/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?\z/

      def merge_uri_references(base, reference)
        base_match = URI_REGEXP.match(base)
        reference_match = URI_REGEXP.match(reference)
        _, base_scheme, base_authority, base_path,
           base_query, _base_fragment = base_match.to_a
        _, scheme, authority, path, query, fragment = reference_match.to_a

        target_scheme = scheme || base_scheme
        target_authority = authority || base_authority

        target_path = if scheme || authority
                        remove_dot_segments(path)
                      elsif path.empty?
                        base_path
                      elsif path.start_with?("/")
                        remove_dot_segments(path)
                      else
                        base_directory = base_path[%r{.*/}] || (base_authority ? "/" : "")
                        remove_dot_segments(base_directory + path)
                      end
        target_query = query || (base_query if path.empty? && scheme.nil? && authority.nil?)

        uri = +""
        uri << target_scheme << ":" if target_scheme
        uri << "//" << target_authority if target_authority
        uri << target_path
        uri << "?" << target_query unless target_query.nil?
        uri << "#" << fragment unless fragment.nil?
        uri
      end

      def remove_dot_segments(path)
        stack = []
        path.split("/").each do |segment|
          case segment
          when "."
          when ".."
            stack.pop unless stack.empty?
          else
            stack << segment unless segment.empty?
          end
        end
        normalized = stack.join("/")
        normalized << "/" if path.end_with?("/") && !normalized.end_with?("/")
        path.start_with?("/") ? "/#{normalized}" : normalized
      end
    end

    C14n11 = CanonicalXML11
    C14N = CanonicalXML11
  end
end
