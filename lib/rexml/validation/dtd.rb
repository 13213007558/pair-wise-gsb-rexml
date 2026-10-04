# frozen_string_literal: false
require_relative "validationexception"
require_relative "../xmltokens"

module REXML
  module Validation
    class DTD
      include XMLTokens

      class Error < ValidationException
        attr_reader :node, :declaration, :attribute

        def initialize(message, node: nil, declaration: nil, attribute: nil)
          super(message)
          @node = node
          @declaration = declaration
          @attribute = attribute
        end
      end

      def self.validate(document)
        new(document).validate
      end

      def self.errors(document)
        new(document).errors
      end

      def initialize(document)
        @document = document
        @doctype = document.doctype
      end

      def validate
        validation_errors.each do |error|
          raise error
        end
        true
      end

      alias validate! validate

      def validation_errors
        return [] unless @doctype

        @errors = []
        @ids = {}
        @id_reference_attributes = []

        validate_declarations
        validate_root
        validate_elements if @document.root
        validate_id_references unless external_dtd?
        @errors
      ensure
        @ids = nil
        @id_reference_attributes = nil
      end

      alias errors validation_errors

      private

      def validate_declarations
        validate_element_declarations
        validate_attribute_declarations
      end

      def validate_element_declarations
        seen = {}
        @doctype.grep(ElementDecl).each do |declaration|
          if seen.key?(declaration.name)
            add_error("Duplicate element declaration for #{declaration.name.inspect}",
                      declaration: declaration)
          else
            seen[declaration.name] = declaration
          end
        end
      end

      def validate_attribute_declarations
        element_definitions = {}
        id_counts = Hash.new(0)
        @doctype.grep(AttlistDecl).each do |declaration|
          seen = element_definitions[declaration.element_name] ||= {}
          declaration.definitions.each do |definition|
            name = definition.name
            if seen.key?(name)
              add_error("Duplicate attribute declaration #{name.inspect} for element #{declaration.element_name.inspect}",
                        declaration: declaration,
                        attribute: name)
            else
              seen[name] = definition
            end
            id_counts[declaration.element_name] += 1 if definition.type == "ID"
            validate_declared_default(definition, declaration)
          end
        end
        id_counts.each do |element_name, count|
          next unless count > 1

          add_error("Multiple ID attributes declared for element #{element_name.inspect}",
                    declaration: @doctype.grep(AttlistDecl).find do |attlist|
                      attlist.element_name == element_name
                    end)
        end
      end

      def validate_declared_default(definition, declaration)
        return if definition.default.nil?

        error_message = attribute_value_error(definition, definition.default)
        return unless error_message

        add_error("Default attribute #{definition.name.inspect} #{error_message}",
                  declaration: declaration,
                  attribute: definition.name)
      end

      def validate_root
        root = @document.root
        return unless root

        if root.expanded_name != @doctype.name
          add_error("Root element #{root.expanded_name.inspect} does not match document type #{@doctype.name.inspect}",
                    node: root)
        end
      end

      def validate_elements
        each_element(@document.root) do |element|
          validate_element(element)
        end
      end

      def validate_element(element)
        declaration = element_declaration_for(element)
        if declaration.nil?
          unless external_dtd?
            add_error("Element #{element.expanded_name.inspect} is not declared",
                      node: element)
          end
          return
        end

        validate_content(element, declaration)
        validate_attributes(element, declaration)
      end

      def element_declaration_for(element)
        @doctype.element_declarations[element.expanded_name]
      end

      def validate_content(element, declaration)
        model = declaration.content_model
        child_nodes = element.children

        case model
        when :empty
          unless child_nodes.all? { |child| child.is_a?(Comment) || child.is_a?(Instruction) }
            add_error("Element #{element.expanded_name.inspect} must be empty",
                      node: element,
                      declaration: declaration)
          end
        when :any
          validate_any_content(element, declaration)
        when Array
          if model[0] == :mixed
            validate_mixed_content(element, declaration, model[1])
          else
            validate_element_content(element, declaration, model)
          end
        end
      end

      def validate_any_content(element, declaration)
        element.children.grep(Element).each do |child|
          next if external_dtd? || element_declaration_for(child)

          add_error("Element #{child.expanded_name.inspect} is not declared",
                    node: child)
        end
      end

      def validate_mixed_content(element, declaration, allowed_names)
        allowed = allowed_names.each_with_object({}) { |name, names| names[name] = true }
        element.children.each do |child|
          next if child.is_a?(Comment) || child.is_a?(Instruction)

          if child.is_a?(Element)
            unless allowed.key?(child.expanded_name)
              add_error("Element #{child.expanded_name.inspect} is not allowed in mixed content",
                        node: child,
                        declaration: declaration)
            end
          elsif !child.is_a?(Text)
            add_error("Node #{child.node_type.inspect} is not allowed in mixed content",
                      node: child,
                      declaration: declaration)
          end
        end
      end

      def validate_element_content(element, declaration, model)
        child_elements = element.children.grep(Element)
        invalid_node = element.children.find do |child|
          if child.instance_of?(Text)
            !child.value.strip.empty?
          elsif child.is_a?(Text)
            true
          else
            false
          end
        end

        if invalid_node
          add_error("Element #{element.expanded_name.inspect} has character data in element-only content",
                    node: invalid_node,
                    declaration: declaration)
        end
        unless matches_particle?(model, child_elements, 0).include?(child_elements.size)
          add_error("Element #{element.expanded_name.inspect} does not satisfy its content model",
                    node: element,
                    declaration: declaration)
        end
      end

      def matches_particle?(particle, elements, index)
        case particle[0]
        when :element
          matches_element_particle?(particle, elements, index)
        else
          matches_group_particle?(particle, elements, index)
        end
      end

      def matches_element_particle?(particle, elements, index)
        _kind, name, occurrence = particle
        count = 0
        while index + count < elements.size && elements[index + count].expanded_name == name
          count += 1
        end
        possible_counts(occurrence, count, elements.size - index).map do |matched|
          index + matched
        end
      end

      def matches_group_particle?(particle, elements, index)
        kind, children, occurrence = particle
        one_match = lambda do |position|
          if kind == :choice
            children.flat_map { |child| matches_particle?(child, elements, position) }
          else
            match_sequence(children, elements, position)
          end.uniq
        end

        minimum, unbounded, maximum = occurrence_limits(occurrence)
        positions = minimum.zero? ? [index] : []
        current = [index]
        minimum.times do
          current = current.flat_map(&one_match).uniq
        end
        positions.concat(current) if minimum.positive?

        if unbounded
          until current.empty?
            current = current.flat_map(&one_match).uniq
            current -= positions
            positions.concat(current)
          end
        else
          (maximum - minimum).times do
            current = current.flat_map(&one_match).uniq
            positions.concat(current)
          end
        end
        positions.uniq
      end

      def match_sequence(particles, elements, index)
        positions = [index]
        particles.each do |particle|
          positions = positions.flat_map do |position|
            matches_particle?(particle, elements, position)
          end.uniq
          break if positions.empty?
        end
        positions
      end

      def possible_counts(occurrence, available, maximum)
        case occurrence
        when :once
          available >= 1 ? [1] : []
        when :optional
          [0] + (available >= 1 ? [1] : [])
        when :one_or_more
          available >= 1 ? (1..available).to_a : []
        else
          (0..available).to_a
        end
      end

      def occurrence_limits(occurrence)
        case occurrence
        when :once
          [1, false, 1]
        when :optional
          [0, false, 1]
        when :one_or_more
          [1, true, nil]
        else
          [0, true, nil]
        end
      end

      def validate_attributes(element, declaration)
        definitions = @doctype.attribute_declarations[element.expanded_name] || {}
        attribute_declarations = @doctype.grep(AttlistDecl).select do |attlist|
          attlist.element_name == element.expanded_name
        end

        unless external_dtd?
          element.attributes.each_attribute do |attribute|
            next if definitions.key?(attribute.expanded_name)

            add_error("Attribute #{attribute.expanded_name.inspect} is not declared for element #{element.expanded_name.inspect}",
                      node: element,
                      declaration: attribute_declarations.first,
                      attribute: attribute.expanded_name)
          end
        end

        definitions.each do |name, definition|
          attribute = element.attributes.get_attribute(name)
          if attribute.nil? && definition.required
            add_error("Required attribute #{name.inspect} is missing",
                      node: element,
                      declaration: declaration_for_attribute(attribute_declarations, name),
                      attribute: name)
            next
          end

          next unless attribute

          if definition.fixed && attribute.value != definition.default
            add_error("Attribute #{name.inspect} must be fixed to #{definition.default.inspect}",
                      node: element,
                      declaration: declaration_for_attribute(attribute_declarations, name),
                      attribute: name)
          end

          error_message = attribute_value_error(definition, attribute.value)
          next if error_message && attribute.value == definition.default
          if error_message
            add_error("Attribute #{name.inspect} #{error_message}",
                      node: element,
                      declaration: declaration_for_attribute(attribute_declarations, name),
                      attribute: name)
          end
        end
      end

      def declaration_for_attribute(declarations, name)
        declarations.find do |declaration|
          declaration.definitions.any? { |definition| definition.name == name }
        end
      end

      def attribute_value_error(definition, value)
        case definition.type
        when "CDATA"
          nil
        when "ID"
          name?(value) ? nil : "must be an XML Name"
        when "IDREF"
          name?(value) ? nil : "must be an ID reference"
        when "IDREFS"
          tokens?(value) { |token| name?(token) } ? nil : "must contain ID references"
        when "NMTOKEN"
          nmtoken?(value) ? nil : "must be an NMTOKEN"
        when "NMTOKENS"
          tokens?(value) { |token| nmtoken?(token) } ? nil : "must contain NMTOKENs"
        when "ENTITY"
          unparsed_entity?(value) ? nil : "must refer to an unparsed entity"
        when "ENTITIES"
          tokens?(value) { |token| unparsed_entity?(token) } ? nil : "must refer to unparsed entities"
        when "ENUMERATION", "NOTATION"
          unless definition.enumeration.include?(value)
            return "must be one of #{definition.enumeration.inspect}"
          end
          if definition.type == "NOTATION" && @doctype.notation(value).nil?
            return "must refer to a declared notation"
          end

          nil
        end
      end

      def record_id_use(element, name, value, definition)
        if definition.type == "ID"
          if @ids.key?(value)
            add_error("Duplicate ID #{value.inspect}",
                      node: element,
                      attribute: name)
          else
            @ids[value] = [element, name]
          end
        else
          value.split(/\s+/).reject(&:empty?).each do |reference|
            @id_reference_attributes << [element, name, reference]
          end
        end
      end

      def validate_id_references
        return if external_dtd?

        each_element(@document.root) do |element|
          definitions = @doctype.attribute_declarations[element.expanded_name] || {}
          definitions.each do |name, definition|
            next unless definition.type == "ID" || definition.type == "IDREF" || definition.type == "IDREFS"

            attribute = element.attributes.get_attribute(name)
            value = attribute ? attribute.value : definition.default
            next if value.nil?
            record_id_use(element, name, value, definition) if valid_id_value?(definition, value)
          end
        end

        @id_reference_attributes.each do |element, name, reference|
          next if @ids.key?(reference)

          add_error("ID reference #{reference.inspect} does not refer to an ID",
                    node: element,
                    attribute: name)
        end
      end

      def external_dtd?
        !@doctype.external_id.nil?
      end

      def each_element(element, &block)
        return enum_for(__method__, element) unless block_given?

        yield element
        element.children.grep(Element).each do |child|
          each_element(child, &block)
        end
      end

      def name?(value)
        /\A#{NAME_STR}\z/ou.match?(value)
      end

      def valid_id_value?(definition, value)
        if definition.type == "IDREFS"
          value.split(/\s+/).reject(&:empty?).all? { |token| name?(token) }
        else
          name?(value)
        end
      end

      def nmtoken?(value)
        /\A#{NMTOKEN}\z/ou.match?(value)
      end

      def tokens?(value)
        values = value.split(/\s+/).reject(&:empty?)
        !values.empty? && values.all? { |token| yield(token) }
      end

      def unparsed_entity?(name)
        entity = @doctype.entities[name]
        entity.is_a?(Entity) && !entity.ndata.nil?
      end

      def add_error(message, node: nil, declaration: nil, attribute: nil)
        @errors << Error.new(message,
                             node: node,
                             declaration: declaration,
                             attribute: attribute)
      end
    end
  end
end
