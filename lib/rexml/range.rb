# frozen_string_literal: false
require_relative "element"
require_relative "text"
require_relative "cdata"

module REXML
  # A character range over an REXML document.
  #
  # Endpoints are a Text or CData node and a zero-based logical-character
  # offset. Offsets count unnormalized characters, not bytes or serialized
  # characters. CData is treated literally. In ordinary Text, entity and
  # character references are atomic: a boundary may be immediately before or
  # after a reference, but not inside its expanded value. References included
  # in an extracted fragment are retained in serialized form.
  #
  # Partial elements are represented by copied shells, while nodes that are
  # completely selected are moved as their original objects. Copied shells
  # retain namespace declarations needed for the fragment and omit ID
  # attributes to avoid duplicate IDs.
  class Range
    class BoundaryMarker < Text
      def initialize
        super("", true)
      end
    end
    private_constant :BoundaryMarker

    attr_reader :start_node, :start_offset, :end_node, :end_offset

    # :call-seq:
    #   Range.new(start_node, start_offset, end_node, end_offset)
    #
    # Creates a character range. Reversed endpoints are normalized to document
    # order.
    def initialize(start_node, start_offset, end_node, end_offset)
      validate_text_node(start_node, "start_node")
      validate_text_node(end_node, "end_node")
      validate_integer(start_offset, "start_offset")
      validate_integer(end_offset, "end_offset")

      if start_node.parent.nil? || end_node.parent.nil?
        raise ArgumentError, "range endpoints must be attached to a parent"
      end
      if root_of(start_node).nil? || root_of(start_node) != root_of(end_node)
        raise ArgumentError, "range endpoints must be in the same tree"
      end

      @start_node = start_node
      @start_offset = start_offset
      @end_node = end_node
      @end_offset = end_offset
      normalize_endpoints!
      validate_offsets!
      @selected_text = calculate_text
    end

    # Returns the logical text selected by the range. The value remains
    # available after #extract or #surround.
    def text
      @selected_text.dup
    end

    # Splits boundary text nodes, moves the selected content out of the
    # source tree, and returns it under a copied common-ancestor shell. A
    # zero-length range returns an empty common-ancestor shell and leaves the
    # source unchanged.
    def extract
      operate(mode: :extract)
    end

    # Splits boundary text nodes and moves the selected content into
    # +wrapper+, which is inserted into the source tree. Returns +wrapper+.
    # A zero-length range inserts an empty wrapper at the boundary.
    def surround(wrapper)
      wrapper = prepare_wrapper(wrapper)
      operate(mode: :surround, wrapper: wrapper)
    end

    private

    def validate_text_node(node, name)
      unless node.is_a?(Text)
        raise TypeError, "#{name} must be an REXML::Text or REXML::CData"
      end
    end

    def validate_integer(value, name)
      unless value.is_a?(Integer)
        raise TypeError, "#{name} must be an Integer"
      end
    end

    def normalize_endpoints!
      comparison = compare_nodes(@start_node, @end_node)
      if comparison > 0 || (comparison.zero? && @start_offset > @end_offset)
        @start_node, @end_node = @end_node, @start_node
        @start_offset, @end_offset = @end_offset, @start_offset
      end
    end

    def validate_offsets!
      validate_offset(@start_node, @start_offset, "start_offset")
      validate_offset(@end_node, @end_offset, "end_offset")
    end

    def validate_offset(node, offset, label)
      segments = logical_segments(node)
      length = segments.sum { |segment| segment[:text].length }
      if offset < 0 || offset > length
        raise ArgumentError, "#{label} is outside the text node"
      end

      position = 0
      segments.each do |segment|
        current_length = segment[:text].length
        if offset > position && offset < position + current_length && segment[:reference?]
          raise ArgumentError,
                "#{label} cannot be in the middle of an entity or character reference"
        end
        position += current_length
      end
    end

    def operate(mode:, wrapper: nil)
      validate_offsets!
      common = lowest_common_ancestor
      unless common.is_a?(Element)
        raise ArgumentError, "range common ancestor must be an element"
      end

      if zero_length?
        if mode == :surround
          insert_empty_wrapper(common, wrapper)
        elsif mode == :extract
          fragment = copied_shell(common)
          add_inherited_namespaces(fragment, common.namespaces)
          return fragment
        end
        return wrapper
      end

      start_marker, end_marker = split_endpoints
      target = mode == :extract ? copied_shell(common) : common
      add_inherited_namespaces(target, common.namespaces) if mode == :extract
      transfer_children(common, target, start_marker, end_marker, :outside,
                        mode: mode, wrapper: wrapper, common: common)
      if mode == :surround
        if start_marker.parent.equal?(common)
          common.insert_after(start_marker, wrapper)
        else
          insertion_anchor = start_marker
          insertion_anchor = insertion_anchor.parent until insertion_anchor.parent.equal?(common)
          common.insert_after(insertion_anchor, wrapper)
        end
      end
      remove_marker(start_marker)
      remove_marker(end_marker)
      mode == :extract ? target : wrapper
    end

    def add_inherited_namespaces(element, namespaces)
      namespaces.each do |prefix, uri|
        next if prefix == "xml"
        name = prefix == "xmlns" ? "xmlns" : "xmlns:#{prefix}"
        next if element.attributes.get_attribute(name)
        if prefix == "xmlns"
          element.add_namespace(uri)
        else
          element.add_namespace(prefix, uri)
        end
      end
    end

    def insert_empty_wrapper(common, wrapper)
      unless @start_node.equal?(@end_node)
        @start_node.parent.insert_after(@start_node, wrapper)
        return
      end

      node = @start_node
      before = make_text(node, source_slice(node, 0, @start_offset))
      after = make_text(node, source_slice(node, @start_offset, logical_length(node)))
      node.parent.insert_before(node, before) if before
      node.parent.insert_before(node, wrapper)
      node.parent.insert_before(node, after) if after
      node.remove
    end

    def zero_length?
      if @start_node.equal?(@end_node)
        return @start_offset == @end_offset
      end

      @start_offset == logical_length(@start_node) &&
        @end_offset.zero? &&
        adjacent_endpoints?
    end

    def adjacent_endpoints?
      first_path = ancestor_chain(@start_node.parent)
      second_path = ancestor_chain(@end_node.parent)
      common = first_path.find { |ancestor| second_path.include?(ancestor) }
      return false unless common

      first_index = first_path.index(common)
      second_index = second_path.index(common)
      first_child = first_index.zero? ? @start_node : first_path[first_index - 1]
      second_child = second_index.zero? ? @end_node : second_path[second_index - 1]
      common.index(first_child) + 1 == common.index(second_child)
    end

    def prepare_wrapper(wrapper)
      wrapper = Element.new(wrapper) if wrapper.is_a?(String)
      unless wrapper.is_a?(Element)
        raise TypeError, "wrapper must be an REXML::Element or element name"
      end
      if wrapper.parent
        raise ArgumentError, "wrapper must not already be attached to a tree"
      end
      if wrapper.size > 0
        raise ArgumentError, "wrapper must be empty"
      end
      wrapper
    end

    def split_endpoints
      if @start_node.equal?(@end_node)
        split_single_node
      else
        [split_start(@start_node, @start_offset), split_end(@end_node, @end_offset)]
      end
    end

    def split_single_node
      node = @start_node
      parent = node.parent
      before = make_text(node, source_slice(node, 0, @start_offset))
      selected = make_text(node, source_slice(node, @start_offset, @end_offset))
      after = make_text(node, source_slice(node, @end_offset, logical_length(node)))
      start_marker = BoundaryMarker.new
      end_marker = BoundaryMarker.new
      [before, start_marker, selected, end_marker, after].compact.each do |child|
        parent.insert_before(node, child)
      end
      node.remove
      [start_marker, end_marker]
    end

    def split_start(node, offset)
      parent = node.parent
      marker = BoundaryMarker.new
      before = make_text(node, source_slice(node, 0, offset))
      selected = make_text(node, source_slice(node, offset, logical_length(node)))
      parent.insert_before(node, before) if before
      parent.insert_before(node, marker)
      parent.insert_before(node, selected) if selected
      node.remove
      marker
    end

    def split_end(node, offset)
      parent = node.parent
      selected = make_text(node, source_slice(node, 0, offset))
      marker = BoundaryMarker.new
      after = make_text(node, source_slice(node, offset, logical_length(node)))
      parent.insert_before(node, selected) if selected
      parent.insert_before(node, marker)
      parent.insert_before(node, after) if after
      node.remove
      marker
    end

    def remove_marker(marker)
      marker.remove if marker.parent
    end

    def transfer_children(source, target, start_marker, end_marker, state,
                          mode:, wrapper:, common:)
      children = source.children.dup

      children.each do |child|
        if child.equal?(start_marker)
          state = :inside
          next
        elsif child.equal?(end_marker)
          state = :outside
          next
        end

        if ancestor?(start_marker, child)
          transfer_boundary_child(child, target, start_marker, end_marker, :before,
                                  mode, wrapper, common)
          state = :inside
          next
        elsif ancestor?(end_marker, child)
          transfer_boundary_child(child, target, start_marker, end_marker, :inside,
                                  mode, wrapper, common)
          state = :outside
          next
        end

        move_selected(child, target, mode, wrapper, source) if state == :inside
      end
    end

    def transfer_boundary_child(child, target, start_marker, end_marker, state,
                                mode, wrapper, common)
      copy = mode == :extract ? copied_shell(child) : child
      target << copy if mode == :extract
      transfer_children(child, copy, start_marker, end_marker, state,
                        mode: mode, wrapper: wrapper, common: common)
    end

    def move_selected(child, target, mode, wrapper, _source)
      destination = mode == :surround ? wrapper : target
      destination << child
    end

    def copied_shell(element)
      copy = element.clone
      copy.attributes.each_attribute { |attribute| attribute.element = copy }
      remove_id_attributes(copy)
      copy
    end

    def remove_id_attributes(element)
      element.attributes.each_attribute do |attribute|
        next unless id_attribute?(element, attribute)
        element.attributes.delete(attribute.expanded_name)
      end
    end

    def id_attribute?(element, attribute)
      name = attribute.expanded_name
      return true if name == "id"
      return true if name == "xml:id"
      dtd = element.document&.doctype
      dtd && dtd.attribute_of(element.expanded_name, name) == "ID"
    end

    def ancestor?(node, candidate)
      current = node.parent
      while current
        return true if current.equal?(candidate)
        current = current.parent
      end
      false
    end

    def collect_text(source, result, state)
      source.children.each do |child|
        if child.equal?(@start_node)
          state = :inside
          if child.equal?(@end_node)
            result << text_value(child)[@start_offset, @end_offset - @start_offset]
            state = :outside
          else
            result << text_value(child)[@start_offset, logical_length(child) - @start_offset]
          end
        elsif child.equal?(@end_node)
          result << text_value(child)[0, @end_offset]
          state = :outside
        elsif child.is_a?(Parent)
          collect_text(child, result, state == :inside ? :inside : :outside)
        elsif state == :inside && child.is_a?(Text)
          result << text_value(child)
        end
      end
    end

    def make_text(original, source)
      return nil if source.empty?
      if original.is_a?(CData)
        CData.new(source, true)
      elsif original.raw
        Text.new(source, true, nil, true, original.instance_variable_get(:@entity_filter))
      else
        Text.new(Text.unnormalize(source, original.doctype), true, nil, false,
                 original.instance_variable_get(:@entity_filter))
      end
    end

    def source_slice(node, start_offset, end_offset)
      return "" if end_offset <= start_offset
      position = 0
      result = +""

      logical_segments(node).each do |segment|
        length = segment[:text].length
        slice_start = [start_offset - position, 0].max
        slice_end = [end_offset - position, length].min
        if slice_start < slice_end
          if segment[:reference?]
            result << segment[:source]
          else
            result << segment[:source][slice_start, slice_end - slice_start]
          end
        end
        position += length
      end
      result
    end

    def logical_length(node)
      logical_segments(node).sum { |segment| segment[:text].length }
    end

    def logical_segments(node)
      value = text_value(node)
      source = node.instance_variable_get(:@string)
      return [{text: value, source: source, reference?: false}] if node.is_a?(CData)

      segments = []
      position = 0
      source.scan(Text::REFERENCE) do
        match = Regexp.last_match
        if match.begin(0) > position
          literal = source[position...match.begin(0)]
          segments << {text: Text.unnormalize(literal, node.doctype), source: literal,
                        reference?: false}
        end
        segments << {text: Text.unnormalize(match[0], node.doctype), source: match[0],
                      reference?: true}
        position = match.end(0)
      end
      if position < source.length
        literal = source[position..-1]
        segments << {text: Text.unnormalize(literal, node.doctype), source: literal,
                      reference?: false}
      end
      segments
    end

    def text_value(node)
      node.value
    end

    def compare_nodes(first, second)
      first_path = ancestor_chain(first.parent)
      second_path = ancestor_chain(second.parent)
      first_path.each_with_index do |ancestor, depth|
        index = second_path.index(ancestor)
        next unless index

        first_child = depth.zero? ? first : first_path[depth - 1]
        second_child = index.zero? ? second : second_path[index - 1]
        return ancestor.index(first_child) <=> ancestor.index(second_child)
      end
      raise ArgumentError, "range endpoints must be in the same tree"
    end

    def lowest_common_ancestor
      first_path = ancestor_chain(@start_node.parent)
      second_path = ancestor_chain(@end_node.parent)
      first_path.find { |ancestor| second_path.include?(ancestor) }
    end

    def ancestor_chain(node)
      chain = []
      while node
        chain << node
        node = node.parent
      end
      chain
    end

    def root_of(node)
      current = node
      current = current.parent while current.parent
      current
    end

    def calculate_text
      if @start_node.equal?(@end_node)
        return text_value(@start_node)[@start_offset, @end_offset - @start_offset]
      end

      result = +""
      collect_text(lowest_common_ancestor, result, :outside)
      result
    end
  end
end
