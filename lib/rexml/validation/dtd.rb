# frozen_string_literal: false

require_relative "validationexception"
require_relative "../xmltokens"

module REXML
  module Validation
    # Validates the element-content model of a DTD element declaration.
    #
    # The content model is compiled once. Choice and repetition ambiguity is
    # detected when the model is compiled instead of while matching children.
    #
    #   model = REXML::Validation::DTD.new("<!ELEMENT entry (title, body*)>")
    #   error = model.validate(%w[title body body])
    #
    # A failed match returns a DTD::ValidationError containing the zero-based
    # position of the child that could not be consumed, the actual child name,
    # and the names allowed at that position.
    class DTD
      include XMLTokens

      ELEMENT_DECLARATION_RE = /
        \A\s*<!ELEMENT\s+
        (?<name>#{NAME_STR})\s+
        (?<content>EMPTY|ANY|\(.*\)[?*+]?)\s*>\s*\z
      /uxm
      NAME_RE = /\A#{NAME_STR}/u
      START = Object.new

      attr_reader :element_name, :content, :position

      # Creates a validator from an element declaration or content model.
      def initialize(declaration_or_content, element_name=nil)
        source = declaration_or_content
        if source.respond_to?(:to_str)
          source = source.to_str
        elsif source.respond_to?(:to_s)
          source = source.to_s
        else
          raise TypeError, "DTD content model must be a String"
        end

        match = ELEMENT_DECLARATION_RE.match(source)
        if match
          @element_name = match[:name]
          @content = match[:content].strip
        else
          @element_name = element_name
          @content = source.strip
        end

        compile
      end

      # Resets the consumed child count and automaton state.
      def reset
        @position = 0
        if @type == :any || @type == :mixed
          @current = [nil]
        elsif @type == :element
          @current = @start_state
        else
          @current = []
        end
        self
      end

      # Validates one child and returns nil when it was consumed.
      def feed(child)
        reset unless defined?(@position)

        return nil if ignored_child?(child)
        if text_child?(child)
          @current_text_child = child
          return validate_text
        end

        name = child_name(child)

        expected = expected_names
        next_positions = transition(@current, name)
        if next_positions.empty?
          actual = actual_name(child)
          return ValidationError.new(@position, actual, expected, @type)
        end

        @current = next_positions
        @position += 1
        nil
      end

      # Validates all children and returns nil or a ValidationError.
      def validate(children)
        reset

        error = nil
        each_element(children) do |child|
          error = feed(child)
          break if error
        end
        error ||= finish
        error
      end

      # Returns whether all children satisfy the content model.
      def valid?(children)
        validate(children).nil?
      end

      # Checks whether streamed children form a complete match.
      def finish
        reset unless defined?(@position)
        expected = expected_names
        return nil if accepting?

        if expected.empty?
          ValidationError.new(@position, nil, [], @type)
        else
          ValidationError.new(@position, nil, expected, @type)
        end
      end

      # Element names that can be consumed next; ["*"] means ANY.
      def expected
        reset unless defined?(@position)
        expected_names
      end

      # Whether the compiled model satisfies the deterministic particle rule.
      def deterministic?
        true
      end

      private
      def compile
        case @content
        when "EMPTY"
          @type = :empty
          @root = nil
          @mixed_names = nil
        when "ANY"
          @type = :any
          @root = nil
          @mixed_names = nil
        else
          parser = ModelParser.new(@content)
          @type = parser.type
          @root = parser.particle
          @mixed_names = parser.names

          if @type == :element
            build_automaton
          else
            ensure_unique_mixed_names
          end
        end

      end

      def build_automaton
        @follow = Hash.new {|hash, key| hash[key] = []}
        connect(@root, [])
        build_deterministic_states
      end

      def build_deterministic_states
        start = [START]
        @start_state = start
        @transitions = {start => {}}
        @accepting_states = {}
        pending = [start]

        until pending.empty?
          state = pending.shift
          grouped = Hash.new {|hash, key| hash[key] = []}
          next_positions_for(state).each do |position|
            grouped[position.name] << position
          end
          grouped.each do |name, positions|
            unique = positions.uniq
            if unique.length > 1
              raise ValidationException.new(
                "Non-deterministic DTD content model: #{name.inspect} can match multiple particles"
              )
            end
            next_state = unique
            @transitions[state][name] = next_state
            unless @transitions.key?(next_state)
              @transitions[next_state] = {}
              pending << next_state
            end
          end
          @accepting_states[state] =
            (state == [START] && @root.nullable?) ||
              state.any? {|position| position != START && @root.last.include?(position)}
        end
      end

      def next_positions_for(state)
        positions = []
        positions.concat(@root.first) if state.include?(START)
        state.each do |position|
          next if position == START
          positions.concat(@follow[position])
        end
        positions
      end

      def connect(particle, following)
        case particle
        when ElementParticle
          add_follow(particle, following)
          if particle.repeatable?
            particle.first.each do |position|
              add_follow(position, particle.first)
            end
          end
        when GroupParticle
          child_following = following
          if particle.repeatable?
            child_following = merge_positions(particle.first, child_following)
          end

          if particle.connector == "|"
            particle.children.each do |child|
              connect(child, child_following)
            end
          else
            next_following = child_following
            particle.children.reverse_each do |child|
              connect(child, next_following)
              if child.nullable?
                next_following = merge_positions(child.first, next_following)
              else
                next_following = child.first
              end
            end
          end
        end
      end

      def add_follow(position, next_positions)
        @follow[position] = merge_positions(@follow[position], next_positions)
      end

      def merge_positions(left, right)
        (left + right).uniq
      end

      def ensure_unique_mixed_names
        @mixed_names.each do |name|
          next unless @mixed_names.count(name) > 1
          raise ValidationException.new(
            "Non-deterministic DTD content model: #{name.inspect} appears multiple times in mixed content"
          )
        end
      end

      def transition(positions, name)
        case @type
        when :element
          next_state = @transitions.fetch(positions, {})[name]
          next_state || []
        when :mixed
          @mixed_names.include?(name) ? [nil] : []
        when :any
          [nil]
        else
          []
        end
      end

      def accepting?
        case @type
        when :empty
          @position.zero?
        when :any, :mixed
          @current.include?(nil)
        else
          @accepting_states[@current]
        end
      end

      def expected_names
        case @type
        when :empty
          []
        when :any
          ["*"]
        when :mixed
          @mixed_names
        else
          @transitions.fetch(@current, {}).keys
        end
      end

      def each_element(children)
        if children.respond_to?(:each)
          children.each do |child|
            next if ignored_child?(child)
            yield(child)
          end
        else
          raise TypeError, "children must be enumerable"
        end
      end

      def ignored_child?(child)
        return false unless child.respond_to?(:node_type)
        child.node_type == :comment || child.node_type == :processing_instruction
      end

      def text_child?(child)
        child == :text ||
          (child.is_a?(Array) && child.first == :text) ||
          (child.respond_to?(:node_type) && [:text, :cdata].include?(child.node_type))
      end

      def validate_text
        return nil if @type == :any || @type == :mixed
        return nil if whitespace_text?(@current_text_child)
        ValidationError.text(@position, nil, @type)
      end

      def whitespace_text?(child)
        text =
          case child
          when Symbol
            nil
          when Array
            child[1]
          else
            child.to_s
          end
        text.is_a?(String) && text.strip.empty?
      end

      def child_name(child)
        case child
        when String, Symbol
          child.to_s
        when Array
          child[1] if child.first == :start_element
        else
        if child.respond_to?(:node_type) && child.node_type == :element
          child.respond_to?(:expanded_name) ? child.expanded_name : child.name
        elsif !child.respond_to?(:node_type)
          raise TypeError, "child must be an element name, SAX event, or REXML node"
        end
        end
      end

      def actual_name(child)
        case child
        when String, Symbol
          child.to_s
        when Array
          child[1]
        else
          if child.respond_to?(:expanded_name)
            child.expanded_name
          elsif child.respond_to?(:name)
            child.name
          else
            child.inspect
          end
        end
      end

      class Particle
        attr_accessor :occurrence
        attr_reader :children

        def initialize(children, occurrence=nil)
          @children = children
          @occurrence = occurrence
        end

        def repeatable?
          @occurrence == :* || @occurrence == :+
        end

        def optional?
          @occurrence == :* || @occurrence == :"?"
        end

      end

      class GroupParticle < Particle
        attr_reader :connector

        def initialize(children, connector=nil, occurrence=nil)
          super(children, occurrence)
          @connector = connector
        end

        def nullable?
          return true if optional?
          if @connector == "|"
            children.any?(&:nullable?)
          else
            children.all?(&:nullable?)
          end
        end

        def first
          if @connector == "|"
            return children.flat_map(&:first).uniq
          end
          positions = []
          children.each do |child|
            positions.concat(child.first)
            break unless child.nullable?
          end
          positions.uniq
        end

        def last
          if @connector == ","
            positions = []
            children.reverse_each do |child|
              positions.concat(child.last)
              break unless child.nullable?
            end
            positions.uniq
          else
            children.flat_map(&:last).uniq
          end
        end
      end

      class ElementParticle < Particle
        attr_reader :name

        def initialize(name, occurrence=nil)
          super([], occurrence)
          @name = name
        end

        def nullable?
          optional?
        end

        def first
          [self]
        end

        def last
          [self]
        end
      end

      class ModelParser
        attr_reader :type, :particle, :names

        def initialize(content)
          @source = content.strip
          @type = nil
          @names = nil
          @particle = parse_model
          unless @source.strip.empty?
            error("unexpected content after model")
          end
        end

        private
        def parse_model
          skip_spaces
          unless consume("(")
            error("content model must be EMPTY, ANY, or a parenthesized model")
          end

          skip_spaces
          if consume("#PCDATA")
            parse_mixed
          else
            particle = parse_choice_or_sequence
            skip_spaces
            unless consume(")")
              error("missing closing parenthesis")
            end
            occurrence = parse_occurrence
            particle = GroupParticle.new(particle.children, particle.connector, occurrence) if occurrence
            @type = :element
            particle
          end
        end

        def parse_mixed
          element_names = []
          skip_spaces
          while consume("|")
            skip_spaces
            name = parse_name
            if name == "#PCDATA"
              error("#PCDATA may only appear once in mixed content")
            end
            element_names << name
            skip_spaces
          end

          unless consume(")")
            error("mixed content may only contain #PCDATA and element choices")
          end
          occurrence = parse_occurrence
          unless element_names.empty? || occurrence == :*
            error("mixed element choices must be repeated with *")
          end
          if occurrence && occurrence != :*
            error("mixed content only supports the * occurrence marker")
          end
          if element_names != element_names.uniq
            raise ValidationException.new(
              "Non-deterministic DTD content model: duplicate mixed-content element name"
            )
          end

          @type = :mixed
          @names = element_names
          GroupParticle.new([])
        end

        def parse_choice_or_sequence
          children = [parse_particle]
          connector = nil
          skip_spaces

          while check("|") || check(",")
            current = @source[0]
            if connector && connector != current
              error("choice and sequence connectors cannot be mixed")
            end
            connector = current
            @source = @source[1..-1]
            skip_spaces
            children << parse_particle
            skip_spaces
          end

          GroupParticle.new(children, connector || ",")
        end

        def parse_particle
          skip_spaces
          if consume("(")
            particle = parse_choice_or_sequence
            skip_spaces
            unless consume(")")
              error("missing closing parenthesis")
            end
            occurrence = parse_occurrence
            GroupParticle.new(particle.children, particle.connector, occurrence)
          else
            name = parse_name
            if name == "#PCDATA"
              error("#PCDATA is only allowed in mixed content")
            end
            ElementParticle.new(name, parse_occurrence)
          end
        end

        def parse_name
          match = DTD::NAME_RE.match(@source)
          error("element name expected") unless match
          @source = @source[match[0].length..-1]
          match[0]
        end

        def parse_occurrence
          case @source[0]
          when "?"
            @source = @source[1..-1]
            :"?"
          when "*"
            @source = @source[1..-1]
            :*
          when "+"
            @source = @source[1..-1]
            :+
          end
        end

        def consume(token)
          if @source.start_with?(token)
            @source = @source[token.length..-1]
            true
          else
            false
          end
        end

        def check(token)
          @source.start_with?(token)
        end

        def skip_spaces
          @source = @source.sub(/\A\s+/u, "")
        end

        def error(message)
          raise ValidationException.new("Malformed DTD content model: #{message}")
        end
      end

      class ValidationError
        # Zero-based number of elements already consumed.
        attr_reader :position, :actual, :expected, :content_type
        attr_reader :text

        def initialize(position, actual, expected, content_type, text=nil)
          @position = position
          @actual = actual
          @expected = expected.dup
          @content_type = content_type
          @text = text
        end

        def self.text(position, text, content_type)
          new(position, :text, [], content_type, text)
        end

        def to_s
          if @actual == :text
            return "Validation error after element #{@position}: text is not allowed in element content"
          end
          if @actual.nil?
            allowed = @expected.empty? ? "no elements" : "#{@expected.join(" or ")}"
            "Validation error after element #{@position}: expected #{allowed} but reached end of element"
          else
            "Validation error at element #{@position}: expected #{@expected.join(" or ")} but got #{@actual}"
          end
        end

        alias inspect to_s
      end
    end
  end
end
