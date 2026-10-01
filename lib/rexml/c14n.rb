# frozen_string_literal: false

require "set"
require "uri"
require_relative "xpath"

module REXML
  module C14n
    XML_NAMESPACE = "http://www.w3.org/XML/1998/"
    DEFAULT_NAMESPACE_PREFIX = "xmlns"

    class Canonicalizer
      def initialize(comments: false)
        @comments = comments
      end

      def canonicalize(node, node_set = nil, xpath = nil, namespaces = nil)
        nodes = normalize_nodes(node, node_set, xpath, namespaces)
        @selected_nodes = nodes.to_set
        output = +""
        write_nodes(nodes, output)
        output.force_encoding(::Encoding::UTF_8).b
      end

      private
      def normalize_nodes(node, node_set, xpath, namespaces)
        if xpath
          node_set = XPath.match(node, xpath, namespaces)
        elsif node_set.nil?
          node_set = default_node_set(node)
        elsif node_set.is_a?(String)
          node_set = XPath.match(node, node_set, namespaces)
        end

        nodes = Array(node_set).flatten
        nodes = nodes.reject do |candidate|
          nodes.any? do |other|
            other != candidate && other.is_a?(Element) && descendant?(candidate, other)
          end
        end
        XPathParser.sort(nodes)
      end

      def default_node_set(node)
        case node
        when Document
          node.children
        when Element, Text, Comment, Instruction, Attribute
          [node]
        else
          [node]
        end
      end

      def descendant?(node, ancestor)
        current = node.parent
        while current
          return true if current.equal?(ancestor)
          current = current.parent
        end
        false
      end

      def write_nodes(nodes, output)
        nodes.each do |node|
          write_node(node, output)
        end
      end

      def write_node(node, output)
        case node
        when Document
          node.children.each { |child| write_node(child, output) }
        when Element
          write_element_subtree(node, output)
        when Text, CData
          write_text_node(node, output) unless node.parent.is_a?(Document)
        when Comment
          if @comments && include_selected_node?(node)
            write_comment(node, output)
            output << "\n" if node.parent.is_a?(Document)
          end
        when Instruction
          if include_selected_node?(node)
            write_instruction(node, output)
            output << "\n" if node.parent.is_a?(Document)
          end
        when Attribute
          write_attribute_node(node, output)
        end
      end

      def write_element_subtree(element, output)
        stack = [[element, initial_state(element), nil]]
        until stack.empty?
          current, state, frame = stack.pop
          case current
          when Symbol
            output << "</#{frame[:element].expanded_name}>"
            frame[:changed].each do |prefix, value|
              if value.nil?
                state[:rendered].delete(prefix)
              else
                state[:rendered][prefix] = value
              end
            end
          when Element
            start_element(current, state, frame, output, stack)
          when Text, CData
            write_text_node(current, output) if include_selected_node?(current)
          when Comment
            write_comment(current, output) if @comments && include_selected_node?(current)
          when Instruction
            write_instruction(current, output) if include_selected_node?(current)
          end
        end
      end

      def initial_state(element)
        parent = element.parent
        base = parent.is_a?(Element) ? in_scope_namespaces(parent) : {}
        {base: base, rendered: {}}
      end

      def start_element(element, state, parent_frame, output, stack)
        local = local_namespace_declarations(element)
        selected = @selected_nodes.include?(element)
        frame = {
          local: local,
          parent: parent_frame,
          changed: {},
          element: element,
          current: parent_frame ? parent_frame[:current].merge(local) : state[:base].merge(local),
          selected: selected
        }
        current = frame[:current]
        namespace_attributes = namespace_attributes(element, state, frame, current, local, parent_frame.nil?)
        attributes = regular_attributes(element)
        if canonical11? && selected && !inside_selected_element?(parent_frame)
          attributes = inherited_xml_attributes(element, attributes)
        end

        output << "<#{element.expanded_name}"
        write_namespace_attributes(namespace_attributes, output)
        write_attributes(sort_attributes(attributes), output)

        if element.children.empty?
          output << "></#{element.expanded_name}>"
          restore_frame(state, frame)
        else
          output << ">"
          stack << [:close, state, frame]
          child_state = state.merge(frame: frame)
          element.children.reverse_each { |child| stack << [child, child_state, frame] }
        end
      end

      def subtree_root?(element)
        element.parent.is_a?(Element)
      end

      def include_selected_node?(node)
        return true unless @selected_nodes

        current = node
        while current
          return true if current.is_a?(Element) && @selected_nodes.include?(current)
          current = current.parent
        end
        @selected_nodes.include?(node)
      end

      def inside_selected_element?(frame)
        while frame
          return true if frame[:selected]
          frame = frame[:parent]
        end
        false
      end

      def canonical11?
        true
      end

      def local_namespace_declarations(element)
        declarations = {}
        element.attributes.each_attribute do |attribute|
          next unless attribute.namespace_declaration?

          prefix =
            if attribute.expanded_name == "xmlns"
              DEFAULT_NAMESPACE_PREFIX
            else
              attribute.name
            end
          declarations[prefix] = attribute.value
        end
        declarations
      end

      def in_scope_namespaces(element)
        element._calculate_namespaces
      end

      def parent_active_namespace(prefix, state, parent_frame)
        if parent_frame
          parent_frame[:current][prefix]
        else
          state[:base][prefix]
        end
      end

      def namespace_attributes(element, state, frame, current, local, subtree_root)
        attributes = []
        prefixes = local.keys
        if canonical11? && subtree_root
          prefixes |= state[:base].keys
        end
        if element.prefix.to_s.empty? && !current[DEFAULT_NAMESPACE_PREFIX].to_s.empty?
          prefixes << DEFAULT_NAMESPACE_PREFIX
        end

        prefixes.sort.each do |prefix|
          next unless current.key?(prefix)
          next if prefix == "xml"
          uri = current[prefix]
          next if state[:rendered][prefix] == uri
          next if prefix == DEFAULT_NAMESPACE_PREFIX && !render_default_namespace?(element, uri, local, prefixes, subtree_root)

          remember_rendered(state, frame, prefix)
          state[:rendered][prefix] = uri
          attributes << [prefix, uri]
        end

        sort_namespace_attributes(attributes)
      end

      def render_default_namespace?(element, uri, local, prefixes, subtree_root)
        return true if local.key?(DEFAULT_NAMESPACE_PREFIX)
        return false if uri.to_s.empty?
        prefixes.include?(DEFAULT_NAMESPACE_PREFIX) && element.prefix.to_s.empty?
      end

      def remember_rendered(state, frame, prefix)
        return if frame[:changed].key?(prefix)
        frame[:changed][prefix] = state[:rendered][prefix]
      end

      def restore_frame(state, frame)
        frame[:changed].each do |prefix, value|
          if value.nil?
            state[:rendered].delete(prefix)
          else
            state[:rendered][prefix] = value
          end
        end
      end

      def regular_attributes(element)
        element.attributes.each_attribute.reject(&:namespace_declaration?)
      end

      def inherited_xml_attributes(element, attributes)
        result = attributes.dup
        %w[xml:lang xml:space].each do |name|
          next if result.any? { |attribute| attribute.expanded_name == name }

          current = element
          value = nil
          while current.is_a?(Element)
            attribute = current.attributes.get_attribute(name)
            if attribute && !attribute.namespace_declaration?
              value = attribute.value
              break
            end
            current = current.parent
          end
          result << SyntheticAttribute.new(name, value.to_s) if value
        end

        unless result.any? { |attribute| attribute.expanded_name == "xml:base" }
          value = inherited_xml_base(element)
          result << SyntheticAttribute.new("xml:base", value) if value
        end
        result
      end

      def inherited_xml_base(element)
        values = []
        current = element
        while current.is_a?(Element)
          attribute = current.attributes.get_attribute("xml:base")
          if attribute && !attribute.namespace_declaration?
            values << attribute.value
            break if absolute_uri?(attribute.value)
          end
          current = current.parent
        end
        return nil if values.empty?

        values.reverse.reduce do |base, reference|
          resolve_uri(base, reference)
        end
      end

      def absolute_uri?(value)
        URI.parse(value).absolute?
      rescue URI::Error
        false
      end

      def resolve_uri(base, reference)
        if absolute_uri?(base)
          URI.parse(base).merge(reference).to_s
        else
          merged = URI.parse("http://c14n.invalid/#{base}").merge(reference)
          resolved = merged.path.sub(/\A\//, "")
          resolved << "?#{merged.query}" if merged.query
          resolved << "##{merged.fragment}" if merged.fragment
          resolved
        end
      end

      def sort_namespace_attributes(attributes)
        attributes.sort_by do |prefix, _uri|
          prefix == DEFAULT_NAMESPACE_PREFIX ? "" : prefix
        end
      end

      def sort_attributes(attributes)
        attributes.sort_by do |attribute|
          [attribute.namespace.to_s, attribute.name, attribute.expanded_name]
        end
      end

      def write_namespace_attributes(attributes, output)
        attributes.each do |prefix, uri|
          if prefix == DEFAULT_NAMESPACE_PREFIX
            output << " xmlns="
          else
            output << " xmlns:#{prefix}="
          end
          write_attribute_value(uri, output)
        end
      end

      def write_attributes(attributes, output)
        attributes.each do |attribute|
          output << " #{attribute.expanded_name}="
          write_attribute_value(attribute.value, output)
        end
      end

      def write_attribute_node(attribute, output)
        if attribute.namespace_declaration?
          prefix = attribute.expanded_name == "xmlns" ? DEFAULT_NAMESPACE_PREFIX : attribute.name
          output << "xmlns"
          output << ":#{prefix}" unless prefix == DEFAULT_NAMESPACE_PREFIX
          output << "="
          write_attribute_value(attribute.value, output)
        else
          output << "#{attribute.expanded_name}="
          write_attribute_value(attribute.value, output)
        end
      end

      def write_attribute_value(value, output)
        output << '"'
        write_escaped(value, output, true)
        output << '"'
      end

      def write_text_node(node, output)
        write_escaped(node.value, output, false)
      end

      def write_comment(comment, output)
        output << "<!--"
        output << comment.string
        output << "-->"
      end

      def write_instruction(instruction, output)
        output << "<?"
        output << instruction.target
        if instruction.content
          output << canonical_processing_instruction_leading_whitespace(
            instruction.leading_whitespace || " "
          )
          content = instruction.raw_content || instruction.content
          output << canonical_processing_instruction_content(content)
        end
        output << "?>"
      end

      def canonical_processing_instruction_leading_whitespace(whitespace)
        newline_index = whitespace.index("\n")
        if newline_index
          whitespace[newline_index..]
        else
          " "
        end
      end

      def canonical_processing_instruction_content(content)
        content
          .gsub(/\r\n?/, "\n")
          .sub(/\A[ \t]+/, "")
          .sub(/[ \t]+(?=\n)/, "")
          .sub(/[ \t]+\z/, "")
      end

      def write_escaped(value, output, attribute)
        value.each_char do |character|
          case character
          when "&"
            output << "&amp;"
          when "<"
            output << "&lt;"
          when ">"
            output << "&gt;"
          when '"'
            output << (attribute ? "&quot;" : character)
          when "\t"
            output << (attribute ? "&#x9;" : character)
          when "\n"
            output << (attribute ? "&#xA;" : character)
          when "\r"
            output << "&#xD;"
          else
            output << character
          end
        end
      end

      class SyntheticAttribute
        include Namespace

        attr_reader :value

        def initialize(expanded_name, value)
          self.name = expanded_name
          @value = value
        end

        def namespace(_arg = nil)
          XML_NAMESPACE
        end
      end
    end

    class Canonical11 < Canonicalizer
    end

    class Exclusive < Canonicalizer
      def initialize(comments: false, inclusive_prefixes: [])
        super(comments: comments)
        if inclusive_prefixes.is_a?(String)
          inclusive_prefixes = inclusive_prefixes.split(/[\s]+/)
        end
        @inclusive_prefixes = inclusive_prefixes.map do |prefix|
          prefix == "#default" ? DEFAULT_NAMESPACE_PREFIX : prefix
        end
      end

      private
      def canonical11?
        false
      end

      def namespace_attributes(element, state, frame, current, local, subtree_root)
        used = used_prefixes(element, current)
        @inclusive_prefixes.each do |prefix|
          used << prefix if current.key?(prefix)
        end
        if local.key?(DEFAULT_NAMESPACE_PREFIX) &&
           current[DEFAULT_NAMESPACE_PREFIX].to_s.empty? &&
           parent_active_namespace(DEFAULT_NAMESPACE_PREFIX, state, frame[:parent]).to_s != ""
          used << DEFAULT_NAMESPACE_PREFIX
        end

        attributes = []
        used.uniq.sort.each do |prefix|
          next unless current.key?(prefix)
          next if prefix == "xml"
          uri = current[prefix]
          next if state[:rendered][prefix] == uri
          next if prefix == DEFAULT_NAMESPACE_PREFIX && uri.to_s.empty? &&
                  parent_active_namespace(prefix, state, frame[:parent]).to_s.empty?

          remember_rendered(state, frame, prefix)
          state[:rendered][prefix] = uri
          attributes << [prefix, uri]
        end
        attributes
      end

      def used_prefixes(element, namespaces)
        used = []
        used << element.prefix unless element.prefix.to_s.empty?
        regular_attributes(element).each do |attribute|
          used << attribute.prefix unless attribute.prefix.to_s.empty?
        end
        if element.prefix.to_s.empty? && !namespaces[DEFAULT_NAMESPACE_PREFIX].to_s.empty?
          used << DEFAULT_NAMESPACE_PREFIX
        end
        used
      end

      def render_default_namespace?(_element, _uri, _local, _prefixes, _subtree_root)
        true
      end
    end
  end
end
