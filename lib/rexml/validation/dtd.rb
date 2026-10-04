# frozen_string_literal: false
require "strscan"
require_relative "validationexception"
require_relative "../attlistdecl"
require_relative "../doctype"
require_relative "../text"

module REXML
  module Validation
    # Validates a parsed document against declarations in an internal DTD
    # subset.  External subsets and external parameter entities are not
    # fetched.
    class DTD
      # A validation violation.  +node+ is the document node associated with
      # the violation and +declaration+ is the DTD declaration node that was
      # violated, when one is available.
      Error = Struct.new(:message, :node, :declaration, :code, keyword_init: true) do
        def to_s
          message
        end
      end

      attr_reader :errors, :doctype

      # Creates a validator from a Document or DocType.
      def initialize(document_or_doctype)
        if document_or_doctype.kind_of?(DocType)
          @doctype = document_or_doctype
        else
          @doctype = document_or_doctype.doctype
        end
      end

      # Adds non-#IMPLIED default and #FIXED attributes declared in the
      # internal subset.  This changes the document and is kept separate from
      # #validate so validation can inspect declared defaults without
      # materializing them.
      def apply_default_attributes(document = nil)
        document ||= @doctype.document
        attributes = attribute_definitions
        each_element(document.root).each do |element|
          definitions = attributes[element.expanded_name]
          next unless definitions

          definitions.each_value do |definition|
            next if element.attributes.include?(definition.name)
            next unless definition.presence == :default
            element.add_attribute(definition.name, expanded_default(definition))
          end
        end
        document
      end

      # Returns all validation errors as DTD::Error objects.  ID/IDREF checks
      # use the complete document, so an IDREF before its matching ID is
      # valid while a dangling reference at the end is reported.
      def validate(document = nil)
        document ||= @doctype.document
        @errors = []
        return @errors unless document

        elements = element_declarations
        attributes = attribute_definitions
        external_subset = !@doctype.external_id.nil?
        ids = {}
        references = []

        root_mismatch = document.root && document.root.expanded_name != @doctype.name
        validate_root(document, elements, external_subset)
        each_element(document.root).each do |element|
          next if root_mismatch
          declaration = elements[element.expanded_name]
          if declaration.nil?
            unless external_subset
              add_error("Element <#{element.expanded_name}> is not declared",
                        element, nil, :undeclared_element)
            end
          else
            validate_content(element, declaration)
          end
          validate_attributes(element,
                             attributes[element.expanded_name] || {},
                             ids,
                             references)
        end
        validate_references(ids, references) unless root_mismatch
        @errors
      end

      # Returns true when #validate returns no errors.
      def valid?(document = nil)
        validate(document).empty?
      end

      # Raises ValidationException for the first error.  The exception carries
      # the offending node, the related declaration, an error +code+, and the
      # complete list of collected errors.
      def validate!(document = nil)
        errors = validate(document)
        unless errors.empty?
          exception = ValidationException.new(errors.first.message)
          exception.extend(ErrorContext)
          exception.node = errors.first.node
          exception.declaration = errors.first.declaration
          exception.code = errors.first.code
          exception.errors = errors
          raise exception
        end
        true
      end

      private

      module ErrorContext
        attr_accessor :node, :declaration, :code, :errors
      end

      def validate_root(document, _elements, _external_subset)
        root = document.root
        return unless root
        if root.expanded_name != @doctype.name
          add_error("Root element <#{root.expanded_name}> does not match DOCTYPE name \"#{@doctype.name}\"",
                    root, nil, :root_mismatch)
        end
      end

      def validate_content(element, declaration)
        model = parse_content(declaration.content)
        case model[:kind]
        when :empty
          invalid_children = element.children.reject do |child|
            child.node_type == :comment || child.node_type == :processing_instruction
          end
          unless invalid_children.empty?
            add_content_error(element, declaration, model)
          end
        when :any
          # ANY permits any well-formed children.  Element declarations are
          # checked separately so undeclared children do not become content
          # model errors.
        when :mixed
          allowed_names = model[:names]
          children = element.children.reject do |child|
            child.node_type == :text ||
              child.node_type == :comment ||
              child.node_type == :processing_instruction
          end
          invalid = children.any? do |child|
            child.node_type != :element || !allowed_names.include?(child.expanded_name)
          end
          add_content_error(element, declaration, model) if invalid
        else
          children = element.children.select do |child|
            child.node_type == :element ||
              (child.node_type == :text && child.to_s.strip.empty? == false)
          end
          add_content_error(element, declaration, model) unless match_particles?(model, children, 0)
        end
      end

      def parse_content(content)
        content = content.to_s.strip
        case content
        when /\AEMPTY\z/
          { kind: :empty }
        when /\AANY\z/
          { kind: :any }
        when /\A\(\s*#PCDATA((?:\s*\|\s*#{name_pattern})*)\s*\)\*\z/
          { kind: :mixed, names: $1.scan(/#{name_pattern}/o) }
        else
          { kind: :children, particle: parse_group(content) }
        end
      end

      def parse_group(content)
        scanner = StringScanner.new(content)
        scanner.skip(/\s*/)
        if scanner.skip(/\(\s*/)
          particle = parse_sequence(scanner)
          scanner.skip(/\s*\)/)
          particle[:occurrence] = scanner.scan(/[+*?]/) || nil
          particle
        else
          parse_sequence(scanner)
        end
      end

      def parse_sequence(scanner)
        members = [parse_choice(scanner)]
        while scanner.skip(/\s*,\s*/)
          members << parse_choice(scanner)
        end
        member_named_group(members, :sequence)
      end

      def parse_choice(scanner)
        members = [parse_particle(scanner)]
        while scanner.skip(/\s*\|\s*/)
          members << parse_particle(scanner)
        end
        member_named_group(members, :choice)
      end

      def parse_particle(scanner)
        if scanner.skip(/\(\s*/)
          particle = parse_sequence(scanner)
          scanner.skip(/\s*\)/)
          particle[:occurrence] = scanner.scan(/[+*?]/) || nil
          particle
        else
          name = scanner.scan(/#{name_pattern}/o)
          { kind: :element, name: name, occurrence: scanner.scan(/[+*?]/) || nil }
        end
      end

      def member_named_group(members, kind)
        members.length == 1 ? members.first : { kind: kind, members: members, occurrence: nil }
      end

      def match_particles?(model, children, index)
        particle = model[:particle]
        match_particle?(particle, children, index).any? { |position| position == children.length }
      end

      def match_particle?(particle, children, index)
        case particle[:kind]
        when :element
          if index < children.length && children[index].node_type == :element &&
              children[index].expanded_name == particle[:name]
            next_index = index + 1
            case particle[:occurrence]
            when "?"
              [index, next_index]
            when "*"
              [index] + repeat_element(particle, children, next_index)
            when "+"
              repeat_element(particle, children, next_index)
            else
              [next_index]
            end
          else
            particle[:occurrence] == "*" || particle[:occurrence] == "?" ? [index] : []
          end
        when :group
          positions = match_group_once(particle, children, index)
          case particle[:occurrence]
          when "?"
            (positions + [index]).uniq
          when "*"
            (repeat_group(particle, children, positions, include_initial: true) +
              [index]).uniq
          when "+"
            repeat_group(particle, children, positions, include_initial: true).uniq
          else
            positions
          end
        when :sequence, :choice
          if particle[:occurrence]
            positions = match_group_once(particle, children, index)
            case particle[:occurrence]
            when "?"
              (positions + [index]).uniq
            when "*"
              (repeat_group(particle, children, positions, include_initial: true) +
                [index]).uniq
            when "+"
              repeat_group(particle, children, positions, include_initial: true).uniq
            end
          else
            match_group_once(particle, children, index)
          end
        end
      end

      def repeat_element(particle, children, index)
        position = index
        position += 1 while position < children.length &&
          children[position].node_type == :element &&
          children[position].expanded_name == particle[:name]
        (index..position).to_a
      end

      def repeat_group(group, children, positions, include_initial:)
        result = []
        frontier = positions.uniq
        initial = frontier.dup
        visited = {}
        until frontier.empty?
          position = frontier.shift
          next if visited.key?(position)
          next unless include_initial || !initial.include?(position)
          visited[position] = true
          result << position
          frontier.concat(match_group_once(group, children, position))
        end
        result.sort
      end

      def match_group_once(group, children, index)
        if group[:kind] == :choice
          group[:members].flat_map do |member|
            match_particle?(member, children, index)
          end.uniq
        else
          match_members(group[:members], group[:kind], children, [index])
        end
      end

      def match_members(members, kind, children, positions)
        members.each do |member|
          next_positions = positions.flat_map do |position|
            match_particle?(member, children, position)
          end.uniq
          positions = kind == :choice ? positions | next_positions : next_positions
          return [] if positions.empty? && kind == :sequence
        end
        positions
      end

      def validate_attributes(element, definitions, ids, references)
        unless @doctype.external_id
          element.attributes.each do |name, _|
            unless definitions.key?(name)
              add_error("Attribute \"#{name}\" is not declared on <#{element.expanded_name}>",
                        element.attributes.get_attribute(name), nil, :undeclared_attribute)
            end
          end
        end

        element_id = nil
        definitions.each do |name, definition|
          own = element.attributes.include?(name)
          raw_default = definition.default
          value = own ? element.attributes[name] : raw_default && expanded_default(definition)
          if value.nil?
            if definition.presence == :required
                add_error("Required attribute \"#{name}\" is missing on <#{element.expanded_name}>",
                        element, declaration_for(definition), :missing_attribute)
            end
            next
          end

          if definition.fixed && own && value != definition.default
            add_error("Attribute \"#{name}\" on <#{element.expanded_name}> must be fixed to #{definition.default.inspect}",
                      attribute_node(element, name),
                      declaration_for(definition),
                      :fixed_attribute)
          end
          element_id = validate_attribute_type(element,
                                              name,
                                              value,
                                              definition,
                                              ids,
                                              references,
                                              element_id)
        end
      end

      def validate_attribute_type(element, name, value, definition, ids, references,
                                  element_id)
        node = attribute_node(element, name)
        case definition.type
        when "CDATA"
        when "ID"
          if element_id
            add_error("Multiple ID attributes on <#{element.expanded_name}>",
                      node, declaration_for(definition), :multiple_id_attributes)
            return element_id
          end
          unless valid_name?(value)
            add_invalid_attribute(element, name, value, definition, node)
            return name
          end
          if ids.key?(value)
            add_error("ID #{value.inspect} is duplicated",
                      node, declaration_for(definition), :duplicate_id)
          else
            ids[value] = node
          end
          name
        when "IDREF"
          if valid_name?(value)
            references << [value, node, declaration_for(definition)]
          else
            add_invalid_attribute(element, name, value, definition, node)
          end
        when "IDREFS"
          value.split(/\s+/).each do |reference|
            if valid_name?(reference)
              references << [reference, node, declaration_for(definition)]
            else
              add_invalid_attribute(element, name, value, definition, node)
            end
          end
        when "NMTOKEN"
          add_invalid_attribute(element, name, value, definition, node) unless valid_nmtoken?(value)
        when "NMTOKENS"
          values = value.split(/\s+/)
          add_invalid_attribute(element, name, value, definition, node) if values.empty? || values.any? { |item| !valid_nmtoken?(item) }
        when "ENTITY"
          add_invalid_attribute(element, name, value, definition, node) unless unparsed_entity?(value)
        when "ENTITIES"
          values = value.split(/\s+/)
          add_invalid_attribute(element, name, value, definition, node) if values.empty? || values.any? { |item| !unparsed_entity?(item) }
        when nil, "NOTATION"
          unless definition.enumeration.include?(value)
            add_invalid_attribute(element, name, value, definition, node)
          end
        end
        element_id
      end

      def validate_references(ids, references)
        references.each do |reference, node, definition|
          unless ids.key?(reference)
            add_error("ID reference #{reference.inspect} does not match any ID",
                      node, definition, :dangling_idref)
          end
        end
      end

      def element_declarations
        declarations = {}
        @doctype.children.each do |child|
          next unless child.kind_of?(ElementDecl)
          declarations[child.element_name] = child
        end
        declarations
      end

      def attribute_definitions
        declarations = Hash.new { |hash, key| hash[key] = {} }
        @doctype.children.each do |child|
          next unless child.kind_of?(AttlistDecl)
          child.attribute_definitions.each do |definition|
            declarations[child.element_name][definition.name] ||= definition
          end
        end
        declarations
      end

      def unparsed_entity?(name)
        @doctype.children.any? do |child|
          child.kind_of?(Entity) && child.name == name && child.external && child.ndata
        end
      end

      def each_element(element)
        return [] unless element
        result = [element]
        element.each do |child|
          result.concat(each_element(child)) if child.node_type == :element
        end
        result
      end

      def add_content_error(element, declaration, model)
        add_error("Element content of <#{element.expanded_name}> does not match #{declaration.content}",
                  element, declaration, :invalid_content)
      end

      def declaration_for(definition)
        definition.attlist_declaration
      end

      def expanded_default(definition)
        REXML::Text.unnormalize(definition.default.to_s, @doctype)
      end

      def add_invalid_attribute(element, name, value, definition, node)
        add_error("Value #{value.inspect} of attribute \"#{name}\" on <#{element.expanded_name}> is invalid",
                  node, declaration_for(definition), :invalid_attribute)
      end

      def attribute_node(element, name)
        element.attributes.include?(name) ? element.attributes.get_attribute(name) : element
      end

      def add_error(message, node, declaration, code)
        @errors << Error.new(message: message,
                             node: node,
                             declaration: declaration,
                             code: code)
      end

      def valid_name?(value)
        value =~ /\A#{name_pattern}\z/o
      end

      def valid_nmtoken?(value)
        value =~ /\A#{REXML::XMLTokens::NMTOKEN}\z/o
      end

      def name_pattern
        REXML::XMLTokens::NAME_STR
      end
    end
  end
end
