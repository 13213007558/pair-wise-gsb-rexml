# frozen_string_literal: true

require_relative "element"
require_relative "text"

module REXML
  # A Range describes a document portion by two text-node/character-offset
  # boundary points.  Offsets count logical characters in Text#value:
  # ordinary parsed text and CDATA use the same character positions, while
  # entity references are counted after expansion.  An entity reference is
  # treated atomically, so an offset may be placed before or after it but not
  # inside its expanded value.
  class Range
    FRAGMENT_NAME = "rexml-fragment"

    attr_reader :start_node, :start_offset, :end_node, :end_offset

    def initialize(start_node, start_offset, end_node = start_node,
                   end_offset = start_offset)
      validate_boundary(start_node)
      validate_boundary(end_node)
      unless start_node.root_node.equal?(end_node.root_node)
        raise ArgumentError, "range boundary nodes must be in the same tree"
      end
      validate_offset(start_node, start_offset)
      validate_offset(end_node, end_offset)

      if compare(start_node, start_offset, end_node, end_offset) > 0
        @start_node = end_node
        @start_offset = end_offset
        @end_node = start_node
        @end_offset = start_offset
      else
        @start_node = start_node
        @start_offset = start_offset
        @end_node = end_node
        @end_offset = end_offset
      end
    end

    def collapsed?
      @start_node.equal?(@end_node) && @start_offset == @end_offset
    end

    # Removes selected content and returns it in an Element named
    # +rexml-fragment+.  Elements that are only partially selected are cloned
    # as structural shells, while fully selected nodes remain the real nodes
    # moved from the source.  Namespace declarations needed by the detached
    # shells are copied, and ID attributes are removed from copied shells to
    # prevent duplicate IDs between the two trees.
    def extract_contents
      fragment = Element.new(FRAGMENT_NAME)
      extract_recursively(fragment, common_ancestor) unless collapsed?
      fragment
    end

    # Extracts the range, inserts +element+ at the range's position in the
    # original tree, and moves the extracted nodes into it.  +element+ may be
    # an Element or an element name.  Returns the wrapper element in the tree.
    def surround_contents(element)
      fragment = extract_contents
      wrapper = coerce_wrapper(element)
      raise ArgumentError, "wrapper must not already be in a tree" if wrapper.parent

      fragment.children.dup.each { |child| wrapper << child }
      insert_after_extraction(wrapper)
      wrapper
    end

    private

    def validate_boundary(node)
      unless node.is_a?(Text)
        raise ArgumentError, "range boundary must be a REXML::Text node"
      end
      unless node.parent
        raise ArgumentError, "range boundary text node must have a parent"
      end
    end

    def validate_offset(node, offset)
      unless offset.is_a?(Integer) && offset >= 0 && offset <= node.value.length
        raise IndexError, "range text offset is out of bounds"
      end
      if node.raw && !valid_raw_offset?(node, node.to_s, offset)
        raise IndexError, "range offset cannot split an entity reference"
      end
    end

    def valid_raw_offset?(node, raw, offset)
      position = 0
      logical = 0
      while position < raw.length
        reference = Text::REFERENCE.match(raw, position)
        if reference&.begin(0) == position
          expanded = Text.expand(reference[0], node.doctype, nil)
          return false if offset > logical && offset < logical + expanded.length
          logical += expanded.length
          position += reference[0].length
        else
          logical += 1
          position += 1
        end
        return true if logical == offset
      end
      offset == logical
    end

    def extract_recursively(target, ancestor)
      start_line = child_line(ancestor, @start_node)
      end_line = child_line(ancestor, @end_node)
      start_child, start_text = start_line
      end_child, end_text = end_line

      if start_child.equal?(end_child)
        extract_through_child(target, ancestor, start_child, start_text, end_text)
        return
      end

      selected_full_children = ancestor.children[(ancestor.index(start_child) + 1)...ancestor.index(end_child)]
      selected_full_children.each do |child|
        child.remove
        target << child
      end

      target << extract_partial_child(ancestor, start_child, start_text, true)
      target << extract_partial_child(ancestor, end_child, end_text, false)
    end

    def child_line(ancestor, leaf)
      chain = []
      current = leaf
      until current.parent.equal?(ancestor)
        chain << current
        current = current.parent
      end
      [current, chain]
    end

    def extract_through_child(target, ancestor, child, start_chain, end_chain)
      if child.is_a?(Text)
        extract_same_text(target, child)
        return
      end

      shell = make_shell(child)
      target << shell
      inner_start = start_chain[-2]
      inner_end = end_chain[-2]
      if inner_start.equal?(inner_end)
        extract_recursively(shell, child)
      else
        shell << extract_partial_child(child, inner_start, start_chain[0...-1], true)
        full_between(child, inner_start, inner_end).each do |full_child|
          full_child.remove
          shell << full_child
        end
        shell << extract_partial_child(child, inner_end, end_chain[0...-1], false)
      end
      child.remove if child.children.empty?
    end

    def full_between(parent, first, last)
      parent.children[(parent.index(first) + 1)...parent.index(last)]
    end

    def extract_partial_child(parent, child, chain, starting)
      if child.is_a?(Text)
        return extract_boundary_text(child, starting)
      end

      shell = make_shell(child)
      boundary_child = chain[-2]
      if boundary_child.equal?(child)
        # This only happens when the boundary text is a direct child.
      end
      partial = extract_partial_child(child, boundary_child, chain[0...-1], starting)
      shell << partial if partial
      full_children = starting ?
        child.children[(child.index(boundary_child) + 1)..] :
        child.children[0...child.index(boundary_child)]
      full_children.each do |full_child|
        full_child.remove
        shell << full_child
      end
      child.remove if child.children.empty?
      shell
    end

    def extract_same_text(target, text)
      left, middle, right = split_three(text, @start_offset, @end_offset)
      parent = text.parent
      text.remove
      target << middle
      parent.insert_at(parent.index(left&.parent ? left : right) || 0, left) if left
      parent.insert_after(left, right) if left && right
      parent << right if !left && right
    end

    def extract_boundary_text(text, starting)
      left, right = split_text(text, starting ? @start_offset : @end_offset)
      selected = starting ? right : left
      remaining = starting ? left : right
      if remaining
        text.parent.replace_child(text, remaining)
      else
        text.remove
      end
      selected
    end

    def split_three(text, start_offset, end_offset)
      left, right = split_text(text, start_offset)
      middle, remaining = split_text(right, end_offset - start_offset)
      [left, middle, remaining]
    end

    def split_text(node, offset)
      value = node.value
      if node.raw
        split_raw_text(node, offset)
      elsif node.is_a?(CData)
        [cdata_part(node, value[0, offset]), cdata_part(node, value[offset..])]
      else
        [text_part(node, value[0, offset]), text_part(node, value[offset..])]
      end
    end

    def split_raw_text(node, offset)
      logical = 0
      position = 0
      raw = node.to_s
      left_raw = +""
      while position < raw.length
        reference = Text::REFERENCE.match(raw, position)
        if reference&.begin(0) == position
          expanded = Text.expand(reference[0], node.doctype, nil)
          if offset == logical
            return [text_or_nil(node, left_raw), text_or_nil(node, raw[position..])]
          end
          if offset == logical + expanded.length
            left_raw << reference[0]
            after = position + reference[0].length
            return [text_or_nil(node, left_raw), text_or_nil(node, raw[after..])]
          end
          left_raw << reference[0]
          logical += expanded.length
          position += reference[0].length
        else
          return [text_or_nil(node, left_raw), text_or_nil(node, raw[position..])] if offset == logical
          left_raw << raw[position]
          logical += 1
          position += 1
        end
      end
      [text_or_nil(node, left_raw), nil]
    end

    def text_or_nil(template, raw_value)
      return nil if raw_value.nil? || raw_value.empty?
      if template.is_a?(CData)
        CData.new(raw_value, true)
      else
        Text.new(raw_value, true, nil, true)
      end
    end

    def text_part(template, value)
      return nil if value.empty?
      Text.new(value, true, nil, template.raw)
    end

    def cdata_part(template, value)
      return nil if value.empty?
      CData.new(value, true)
    end

    def make_shell(element)
      shell = element.clone
      copy_namespaces(element, shell)
      remove_shell_ids(shell)
      shell
    end

    def copy_namespaces(source, target)
      source.namespaces.each do |prefix, uri|
        name = prefix == "xmlns" ? "xmlns" : "xmlns:#{prefix}"
        next if target.attributes[name]
        if prefix == "xmlns"
          target.add_namespace(uri)
        else
          target.add_namespace(prefix, uri)
        end
      end
    end

    def remove_shell_ids(element)
      element.attributes.each_attribute do |attribute|
        name = attribute.expanded_name
        if name == "xml:id" || declared_id?(element, name)
          element.delete_attribute(name)
        end
      end
    end

    def declared_id?(element, name)
      doctype = element.document&.doctype
      return false unless doctype
      doctype.children.any? do |declaration|
        next false unless declaration.is_a?(AttlistDecl)
        next false unless declaration.element_name == element.expanded_name
        /\s#{Regexp.escape(name)}\s+ID(?:\s|\z)/.match?(declaration.instance_variable_get(:@contents))
      end
    end

    def coerce_wrapper(wrapper)
      return wrapper if wrapper.is_a?(Element)
      return Element.new(wrapper.to_s) if wrapper.is_a?(String) || wrapper.is_a?(Symbol)
      raise ArgumentError, "wrapper must be an element or element name"
    end

    def insert_after_extraction(wrapper)
      if @start_node.parent.children.include?(@start_node)
        insert_after_start_text(wrapper)
      else
        @start_node.parent << wrapper
      end
    end

    def insert_after_start_text(wrapper)
      parent = @start_node.parent
      index = parent.index(@start_node)
      if index
        parent.insert_at(index + 1, wrapper)
      else
        parent << wrapper
      end
    end

    def common_ancestor
      start_ancestors = Set.new
      node = @start_node
      while node
        start_ancestors << node
        node = node.parent
      end
      node = @end_node
      node = node.parent until start_ancestors.include?(node)
      node
    end

    def compare(start_node, start_offset, end_node, end_offset)
      return start_offset <=> end_offset if start_node.equal?(end_node)
      start_ancestors = ancestors(start_node)
      end_ancestors = ancestors(end_node)
      common = start_ancestors.find { |node| end_ancestors.include?(node) }
      start_child = descendant_below(start_ancestors, common)
      end_child = descendant_below(end_ancestors, common)
      common.index(start_child) <=> common.index(end_child)
    end

    def ancestors(node)
      list = []
      while node
        list << node
        node = node.parent
      end
      list
    end

    def descendant_below(ancestors, ancestor)
      index = ancestors.index(ancestor)
      ancestors[index - 1]
    end
  end

  class Parent
    def insert_at(index, child)
      child.parent.delete(child) if child.parent
      @children.insert(index, child)
      child.parent = self
      child
    end
  end
end
