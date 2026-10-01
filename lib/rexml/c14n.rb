# frozen_string_literal: false

require_relative "attribute"
require_relative "cdata"
require_relative "comment"
require_relative "document"
require_relative "element"
require_relative "instruction"
require_relative "text"

module REXML
  module C14n
    XMLNS_NAMESPACE = "http://www.w3.org/2000/xmlns/"
    XML_NAMESPACE = "http://www.w3.org/XML/1998/namespace"

    XML_C14N_1_0 = 0
    XML_C14N_EXCLUSIVE_1_0 = 1
    XML_C14N_1_1 = 2

    class << self
      def canonicalize(node,
                      mode = XML_C14N_1_1,
                      with_comments = false,
                      inclusive_prefixes = nil,
                      node_set = nil,
                      &block)
        Canonicalizer.new(mode,
                          with_comments,
                          inclusive_prefixes).canonicalize(node,
                                                          node_set,
                                                          &block)
      end
      alias c14n canonicalize
    end

    class Canonicalizer
      def initialize(mode = XML_C14N_1_1,
                     with_comments = false,
                     inclusive_prefixes = nil)
        @mode = resolve_mode(mode)
        @with_comments = with_comments
        @inclusive_prefixes = normalize_prefixes(inclusive_prefixes)
      end

      def canonicalize(node, selected_nodes = nil, &block)
        if block
          selected_nodes = block.call(node)
          selected_nodes = selected_nodes.is_a?(Node) ? [selected_nodes] : selected_nodes.to_a
        elsif selected_nodes.is_a?(Node)
          selected_nodes = [selected_nodes]
        elsif selected_nodes.nil?
          selected_nodes = [node]
        else
          selected_nodes = selected_nodes.to_a
        end

        @selected = {}.compare_by_identity
        selected_nodes.each { |selected_node| @selected[selected_node] = true }
        @selected_elements = selected_nodes.grep(Element).reject do |element|
          selected_nodes.grep(Element).any? do |ancestor|
            !ancestor.equal?(element) && ancestor_or_self?(element, ancestor)
          end
        end
        @root_elements = selected_nodes.grep(Document).map(&:root).compact
        @root_elements.concat(selected_nodes.grep(Element).select do |element|
          element.parent.is_a?(Document)
        end)
        @full_document = selected_nodes.any?(Document)
        @prefix_cache = {}.compare_by_identity
        @output = +"".dup.force_encoding(::Encoding::UTF_8)

        write_roots(build_roots(selected_nodes))
        @output.force_encoding(::Encoding::UTF_8)
      end

      private

      def resolve_mode(mode)
        return mode if mode == XML_C14N_1_0 ||
          mode == XML_C14N_EXCLUSIVE_1_0 ||
          mode == XML_C14N_1_1

        case mode
        when Integer
          if [XML_C14N_1_0, XML_C14N_EXCLUSIVE_1_0, XML_C14N_1_1].include?(mode)
            mode
          else
            raise ArgumentError, "unknown canonicalization mode: #{mode.inspect}"
          end
        when Symbol
          case mode
          when :c14n, :c14n_1_0, :canonical_1_0
            XML_C14N_1_0
          when :c14n_1_1, :canonical_1_1
            XML_C14N_1_1
          when :exclusive, :c14n_exclusive_1_0, :canonical_exclusive_1_0
            XML_C14N_EXCLUSIVE_1_0
          else
            raise ArgumentError, "unknown canonicalization mode: #{mode.inspect}"
          end
        when String
          case mode
          when "http://www.w3.org/TR/2001/REC-xml-c14n-20010315",
               "http://www.w3.org/TR/2001/REC-xml-c14n-20010315#WithComments"
            XML_C14N_1_0
          when "http://www.w3.org/2006/12/xml-c14n11",
               "http://www.w3.org/2006/12/xml-c14n11#WithComments"
            XML_C14N_1_1
          when "http://www.w3.org/2001/10/xml-exc-c14n#",
               "http://www.w3.org/2001/10/xml-exc-c14n#WithComments"
            XML_C14N_EXCLUSIVE_1_0
          else
            raise ArgumentError, "unknown canonicalization mode: #{mode.inspect}"
          end
        else
          raise ArgumentError, "unknown canonicalization mode: #{mode.inspect}"
        end
      end

      def normalize_prefixes(prefixes)
        return [] if prefixes.nil?

        Array(prefixes).flat_map do |prefix|
          prefix = prefix.split(/\s+/) if prefix.is_a?(String)
          Array(prefix)
        end.map do |prefix|
          if prefix.nil? || prefix == "" || prefix == "#default"
            "xmlns"
          else
            prefix.to_s
          end
        end
      end

      def exclusive?
        @mode == XML_C14N_EXCLUSIVE_1_0
      end

      def build_roots(selected_nodes)
        roots = []
        partial_groups = Hash.new { |hash, key| hash[key] = [] }
        selected_nodes.each do |node|
          root = root_for(node)
          next if root.nil?

          if root.is_a?(Array)
            boundary, partial_node = root
            unless @selected_elements.any? { |element|
              element.parent.equal?(boundary) ||
                ancestor_or_self?(boundary, element)
            }
              partial_groups[boundary] << partial_node
            end
          else
            next if root.is_a?(Element) && contained_element?(root, roots)

            roots << root
          end
        end

        partial_groups.each do |boundary, nodes|
          contained = roots.grep(Element).select do |element|
            ancestor_or_self?(element, boundary)
          end
          if contained.any?
            contained.each do |element|
              nodes << element
              roots.delete(element)
            end
          end
          roots << [boundary, nodes]
        end

        roots.uniq { |root| root.is_a?(Array) ? root.first : root }
             .sort_by do |root|
               target = root.is_a?(Array) ? root.first : root
               root.is_a?(Attribute) ? attribute_order_key(target) : order_key(target)
             end
      end

      def root_for(node)
        case node
        when Document
          node
        when Element
          selected_ancestor_element?(node) ? nil : node
        when Attribute
          owner = node.element
          return nil if owner.nil?
          return nil if selected_ancestor_element?(owner)
          return nil if selected_element?(owner)

          return node if node.namespace_declaration?

          boundary = partial_boundary(owner)
          [boundary, node] unless @selected_elements.any? { |element|
            ancestor_or_self?(owner, element)
          } || @root_elements.any? { |element|
            ancestor_or_self?(owner, element)
          }
        when Text, CData, Comment, Instruction
          return nil if node.is_a?(Comment) && !@with_comments

          parent = node.parent
          return nil unless parent
          return node if parent.is_a?(Document)
          return nil unless parent.is_a?(Element)
          return nil if selected_ancestor_element?(parent)
          return nil if selected_element?(parent)
          return nil if @full_document &&
            @root_elements.any? { |element| ancestor_or_self?(parent, element) }

          boundary = partial_boundary(parent)
          [boundary, node] unless @selected_elements.any? do |element|
            ancestor_or_self?(parent, element)
          end || @root_elements.any? do |element|
            ancestor_or_self?(parent, element)
          end
        end
      end

      def partial_boundary(element)
        boundary = element
        while boundary.parent.is_a?(Element)
          return boundary.parent if selected_element?(boundary.parent)

          boundary = boundary.parent
        end
        boundary
      end

      def ancestor_or_self?(node, ancestor)
        current = node
        while current
          return true if current.equal?(ancestor)

          current = current.parent
        end
        false
      end

      def selected_ancestor_element?(node)
        current = node.parent
        while current.is_a?(Element)
          return true if selected_element?(current)

          current = current.parent
        end
        false
      end

      def selected_element?(node)
        node.is_a?(Element) && @selected[node]
      end

      def contained_element?(element, roots)
        roots.any? do |root|
          next false unless root.is_a?(Element)

          current = element.parent
          while current
            return true if current.equal?(root)

            current = current.parent
          end
          false
        end
      end

      def order_key(node)
        path = []
        current = node

        while current
          parent = current.parent
          if parent
            index = parent.children.index { |child| child.equal?(current) }
            path << if index
                      [0, index]
                    elsif current.is_a?(Attribute)
                      [-1, attribute_order_name(current)]
                    else
                      [-2, current.object_id]
                    end
          end
          current = parent
        end

        path.reverse
      end

      def attribute_order_name(attribute)
        "#{attribute_namespace_uri(attribute)}\u0000#{attribute.name}"
      end

      def attribute_order_key(attribute)
        owner = attribute.element
        owner_path = owner ? order_key(owner) : []
        owner_path + [[-1, attribute_order_name(attribute)]]
      end

      def write_roots(roots)
        roots.each do |root|
          case root
          when Document
            write_document(root)
          when Element
            inherited_actual = root.parent.is_a?(Element) ? in_scope_namespaces(root.parent) : {}
            write_full_element(root,
                               inherited_actual,
                               {},
                               true,
                               !exclusive?)
          when Array
            write_partial_group(root.first, root.last)
          when Attribute
            write_namespace_node(root)
          when Comment
            write_comment(root)
          when Instruction
            write_instruction(root)
          end
        end
      end

      def write_document(document)
        document.children.each do |child|
          case child
          when Element
            write_full_element(child,
                               child.parent.is_a?(Element) ? in_scope_namespaces(child.parent) : {},
                               {},
                               false,
                               !exclusive?)
          when Comment
            write_comment(child) if @with_comments
          when Instruction
            write_instruction(child)
          end
        end
      end

      def write_partial_group(boundary, selected_nodes)
        selected = {}.compare_by_identity
        ancestors = {}.compare_by_identity
        selected_nodes.each { |node| selected[node] = true }
        surrounding_elements = @selected_elements.select do |element|
          element.parent.equal?(boundary) ||
            (@selected[boundary] && ancestor_or_self?(element, boundary))
        end
        include_boundary = selected_nodes.any? do |node|
          node.is_a?(Attribute) ? node.element.equal?(boundary) : node.parent.equal?(boundary)
        end

        selected_nodes.each do |node|
          current = node.is_a?(Attribute) ? node.element : node.parent
          while current.is_a?(Element) && !current.equal?(boundary)
            ancestors[current] = true
            current = current.parent
          end
        end

        inherited = boundary.parent.is_a?(Element) ? in_scope_namespaces(boundary.parent) : {}
        if include_boundary || surrounding_elements.any?
          write_partial_element(boundary, selected, ancestors, inherited, {})
        else
          actual = inherited.merge(local_namespaces(boundary))
          write_partial_children(boundary,
                                selected,
                                ancestors,
                                actual,
                                local_namespaces(boundary))
        end
      end

      def write_partial_children(element,
                                 selected_nodes,
                                 ancestors,
                                 actual,
                                 rendered)
        element.children.each do |child|
          case child
          when Element
            if selected_element?(child)
              write_full_element(child, actual, rendered, true, !exclusive?)
            elsif ancestors[child]
              write_partial_element(child,
                                   selected_nodes,
                                   ancestors,
                                   actual,
                                   rendered)
            end
          when Text, CData
            write_text(child) if selected_nodes[child]
          when Comment
            write_comment(child) if @with_comments && selected_nodes[child]
          when Instruction
            write_instruction(child) if selected_nodes[child]
          end
        end
      end

      def write_namespace_node(attribute)
        owner = attribute.element
        return unless owner

        prefix = namespace_attribute_prefix(attribute)
        actual = in_scope_namespaces(owner)
        prefixes = namespace_prefixes(owner,
                                      actual,
                                      {},
                                      forced: [prefix],
                                      subtree_root: false,
                                      include_local_namespaces: false)
        write_start(owner, physical_attributes(owner), actual, prefixes)
        end_element(owner)
      end

      def write_partial_element(element,
                                selected_nodes,
                                ancestors,
                                inherited_actual,
                                rendered)
        own_selected = selected_nodes.keys
        selected_namespaces = own_selected.select do |node|
          node.is_a?(Attribute) &&
            node.element.equal?(element) &&
            node.namespace_declaration?
        end
        selected_attributes = own_selected.select do |node|
          node.is_a?(Attribute) &&
            node.element.equal?(element) &&
            !node.namespace_declaration?
        end
        forced = selected_namespaces.map { |attribute| namespace_attribute_prefix(attribute) }
        selected_attributes.each do |attribute|
          forced << attribute.prefix unless attribute.prefix.empty?
        end

        actual = inherited_actual.merge(local_namespaces(element))
        prefixes = namespace_prefixes(element,
                                      actual,
                                      rendered,
                                      forced: forced,
                                      subtree_root: false,
                                      include_local_namespaces: false)
        write_start(element, selected_attributes, actual, prefixes)
        next_rendered = rendered.merge(prefixes.each_with_object({}) do |prefix, result|
          result[prefix] = actual[prefix]
        end)

        element.children.each do |child|
          case child
          when Element
            if @selected_elements.include?(child)
              write_full_element(child,
                                 actual,
                                 next_rendered,
                                 true,
                                 false)
            elsif ancestors[child]
              write_partial_element(child,
                                   selected_nodes,
                                   ancestors,
                                   actual,
                                   next_rendered)
            end
          when Text, CData
            write_text(child) if selected_nodes[child]
          when Comment
            write_comment(child) if @with_comments && selected_nodes[child]
          when Instruction
            write_instruction(child) if selected_nodes[child]
          end
        end

        end_element(element)
      end

      def write_full_element(element,
                             inherited_actual,
                             inherited_rendered,
                             subtree_root,
                             include_all_local_namespaces = subtree_root)
        stack = [
          [:element, element, inherited_actual, inherited_rendered,
           subtree_root, include_all_local_namespaces]
        ]

        until stack.empty?
          frame = stack.pop
          case frame.first
          when :end
            end_element(frame.last)
          when :text
            write_text(frame.last)
          when :comment
            write_comment(frame.last)
          when :instruction
            write_instruction(frame.last)
          when :element
            _, current,
            inherited_namespaces,
            rendered_namespaces,
            root,
            include_local_namespaces = frame
            actual = inherited_namespaces.merge(local_namespaces(current))
            prefixes = namespace_prefixes(current,
                                         actual,
                                         rendered_namespaces,
                                         subtree_root: root,
                                         include_local_namespaces: include_local_namespaces)
            emitted = write_start(current,
                                  full_attributes(current, root),
                                  actual,
                                  prefixes)
            rendered = rendered_namespaces.merge(emitted)

            children = current.children
            if children.empty?
              end_element(current)
            else
              stack << [:end, current]
              children.reverse_each do |child|
                case child
                when Element
                  stack << [:element, child, actual, rendered, false, false]
                when Text, CData
                  stack << [:text, child]
                when Comment
                  stack << [:comment, child] if @with_comments
                when Instruction
                  stack << [:instruction, child]
                end
              end
            end
          end
        end
      end

      def local_namespaces(element)
        namespaces = {}
        doctype_mapping(element).each do |name, value|
          next unless name == "xmlns" || name.start_with?("xmlns:")

          namespaces[name.delete_prefix("xmlns:")] = value
        end
        element.attributes.each_value do |attribute|
          next unless attribute.namespace_declaration?

          namespaces[namespace_attribute_prefix(attribute)] = attribute.value
        end
        namespaces
      end

      def doctype_mapping(element)
        mappings = element.document&.doctype&._attlist_mappings
        return {} unless mappings

        mappings[element.expanded_name] || {}
      end

      def in_scope_namespaces(element)
        namespaces = element.parent.is_a?(Element) ? in_scope_namespaces(element.parent) : {}
        namespaces.merge(local_namespaces(element))
      end

      def default_namespace_uri(element)
        current = element
        while current.is_a?(Element)
          local = local_namespaces(current)["xmlns"]
          return local if local

          current = current.parent
        end
        nil
      end

      def namespace_attribute_prefix(attribute)
        attribute.expanded_name == "xmlns" ? "xmlns" : attribute.name
      end

      def namespace_prefixes(element,
                             actual,
                             rendered,
                             forced: [],
                             subtree_root: false,
                             include_local_namespaces: subtree_root)
        local = local_namespaces(element)
        candidates = {}

        if exclusive?
          whole_subtree = subtree_root && rendered.empty?
          visible_prefixes(element, whole_subtree).each do |prefix|
            candidates[prefix] = true
          end
          @inclusive_prefixes.each do |prefix|
            used = uses_prefix?(element, prefix)
            declared_here = local.key?(prefix)
            propagated = !subtree_root &&
              subtree_uses_prefix?(element, prefix) &&
              !rendered.key?(prefix)
            candidates[prefix] = true if used || declared_here || propagated
          end
          candidates["xmlns"] = true if local.key?("xmlns") &&
            (uses_prefix?(element, "xmlns") ||
             @inclusive_prefixes.include?("xmlns"))
        else
          if include_local_namespaces
            local.each_key { |prefix| candidates[prefix] = true }
          end
          visible_prefixes(element, false).each do |prefix|
            candidates[prefix] = true
          end
          candidates["xmlns"] = true if subtree_root &&
            element.prefix.empty? &&
            actual.key?("xmlns")
          if !exclusive? && !subtree_root
            visible_prefixes(element, true).each do |prefix|
              candidates[prefix] = true
            end
          end
        end

        forced.each do |prefix|
          prefix = "xmlns" if prefix.empty?
          candidates[prefix] = true unless exclusive? &&
            rendered[prefix] == actual[prefix]
        end

        candidates.keys.reject { |prefix| prefix == "xml" }.sort.select do |prefix|
          next false unless actual.key?(prefix)

          rendered[prefix] != actual[prefix] ||
            (exclusive? && subtree_root && @inclusive_prefixes.include?(prefix))
        end
      end

      def visible_prefixes(element, whole_subtree)
        cache_key = whole_subtree ? :subtree : :element
        cached = @prefix_cache.dig(element, cache_key)
        return cached.keys if cached

        begin
          prefixes = {}
          collect_visible_prefixes(element, whole_subtree, prefixes)
          @prefix_cache[element] ||= {}
          @prefix_cache[element][cache_key] = prefixes
        end.keys
      end

      def collect_visible_prefixes(element, whole_subtree, prefixes, &block)
        if element.prefix.empty?
          uri = default_namespace_uri(element).to_s
          if !uri.empty? && (!exclusive? || local_namespaces(element).key?("xmlns"))
            if block
              block.call("xmlns", uri)
            else
              prefixes["xmlns"] = true
            end
          end
        elsif block
          block.call(element.prefix, element.namespace.to_s)
        else
          prefixes[element.prefix] = true
        end
        element.attributes.each_value do |attribute|
          next if attribute.namespace_declaration?

          if block
            block.call(attribute.prefix, attribute.namespace.to_s) unless attribute.prefix.empty?
          else
            prefixes[attribute.prefix] = true unless attribute.prefix.empty?
          end
        end
        return unless whole_subtree

        element.each_child do |child|
          collect_visible_prefixes(child, true, prefixes, &block) if child.is_a?(Element)
        end
      end

      def uses_prefix?(element, prefix)
        if prefix == "xmlns"
          element.prefix.empty? && default_namespace_uri(element).to_s != ""
        else
          element.prefix == prefix ||
            physical_attributes(element).any? { |attribute| attribute.prefix == prefix }
        end
      end

      def subtree_uses_prefix?(element, prefix)
        visible_prefixes(element, true).include?(prefix)
      end

      def write_start(element, attributes, actual_namespaces, prefixes)
        @output << "<"
        @output << element.expanded_name
        emitted = {}

        prefixes.each do |prefix|
          uri = actual_namespaces[prefix]
          name = prefix == "xmlns" ? "xmlns" : "xmlns:#{prefix}"
          write_attribute_text(name, uri)
          emitted[prefix] = uri
        end

        attributes.each do |attribute|
          write_attribute(attribute)
        end
        @output << ">"
        emitted
      end

      def end_element(element)
        @output << "</#{element.expanded_name}>"
      end

      def full_attributes(element, subtree_root)
        attributes = physical_attributes(element)
        names = attributes.each_with_object({}) do |attribute, result|
          result[attribute.expanded_name] = true
        end

        doctype_mapping(element).each do |name, value|
          next if names[name]
          next if name == "xmlns" || name.start_with?("xmlns:")

          attribute = Attribute.new(name, value)
          attribute.element = element
          attributes << attribute
        end

        if @mode == XML_C14N_1_1 && subtree_root
          inherited_xml_attributes(element).each do |attribute|
            unless names[attribute.expanded_name]
              attributes << attribute
            end
          end
        end

        sort_attributes(attributes)
      end

      def physical_attributes(element)
        element.attributes.each_value.reject(&:namespace_declaration?)
      end

      def inherited_xml_attributes(element)
        inherited = inherited_xml_attribute_values(element)

        ["lang", "space", "base"].each_with_object([]) do |local_name, result|
          next if element.attributes.get_attribute("xml:#{local_name}")

          value = inherited[local_name]
          next if value.nil?

          attribute = Attribute.new("xml:#{local_name}", value)
          attribute.element = element
          result << attribute
        end
      end

      def inherited_xml_attribute_values(element)
        result = {}
        current = element.parent
        while current.is_a?(Element)
          ["lang", "space", "base"].each do |local_name|
            result[local_name] ||= current.attributes.get_attribute("xml:#{local_name}")&.value
          end
          current = current.parent
        end
        result
      end

      def sort_attributes(attributes)
        attributes.sort_by do |attribute|
          prefix = attribute.prefix
          namespace = if prefix == "xml"
                        XML_NAMESPACE
                      elsif prefix.empty?
                        ""
                      else
                        attribute.namespace || ""
                      end
          [namespace, attribute.name, attribute.expanded_name]
        end
      end

      def attribute_namespace_uri(attribute)
        attribute.prefix == "xml" ? XML_NAMESPACE : (attribute.namespace || "")
      end

      def write_attribute(attribute)
        write_attribute_text(attribute.expanded_name, attribute.value)
      end

      def write_attribute_text(name, value)
        @output << " "
        @output << name
        @output << '="'
        write_escaped(value)
        @output << '"'
      end

      def write_text(node)
        @output << escape_text(node.value)
      end

      def write_comment(node)
        @output << "<!--"
        @output << node.string
        @output << "-->"
      end

      def write_instruction(node)
        @output << "<?"
        @output << node.target
        if node.content
          @output << " "
          @output << node.content
        end
        @output << "?>"
      end

      def write_escaped(value)
        value.each_char do |character|
          case character
          when "&"
            @output << "&amp;"
          when "<"
            @output << "&lt;"
          when '"'
            @output << "&quot;"
          when "\r"
            @output << "&#xD;"
          else
            @output << character
          end
        end
      end

      def escape_text(value)
        value.gsub("&", "&amp;").gsub("<", "&lt;").gsub("\r", "&#xD;")
      end
    end
  end
end
