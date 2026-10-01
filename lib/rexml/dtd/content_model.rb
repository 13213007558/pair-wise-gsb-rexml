# frozen_string_literal: false
require_relative "../validation/validationexception"

module REXML
  module DTD
    # A parsed DTD content model: the content specification of an
    # +<!ELEMENT>+ declaration (XML 1.0, sections 3.2.1 and 3.2.2).
    #
    # All four content model kinds are handled:
    #
    # * +EMPTY+ -- no child elements allowed
    # * +ANY+ -- any child elements allowed
    # * mixed content -- <!(#PCDATA)> or <!(#PCDATA|em|strong)*>
    # * element content -- sequence, choice and repetition, such as
    #   +(a, (b|c)*, d?)+
    #
    # Element content models are compiled into a deterministic automaton
    # when the model is parsed.  Models that violate the XML determinism
    # ("unique particle attribution") constraint, for example +(a|a)+ or
    # +((a,b)|(a,c))+, are rejected with AmbiguityError at parse time,
    # before any document instance is read.  Validation then consumes
    # child elements one at a time with constant work per child, so the
    # total effort grows linearly with the number of children and never
    # degrades into backtracking over ambiguous branches.
    #
    #   model = REXML::DTD::ContentModel.parse("(a, (b|c)*, d?)")
    #   model.validate(["a", "b", "c", "d"])  # => true
    #
    #   validator = model.validator
    #   validator.consume("a")   # => true
    #   validator.consume("x")   # => false
    #   validator.position       # => 1
    #   validator.expected       # => ["b", "c", "d"]
    class ContentModel
      # Base class for content model errors.
      class Error < REXML::Validation::ValidationException; end

      # Raised when a content specification cannot be parsed.
      class SyntaxError < Error; end

      # Raised when a content model is not deterministic: the same
      # element name can be matched by more than one position in the
      # model (XML 1.0, "Deterministic Content Models").
      class AmbiguityError < Error
        # The element name that causes the ambiguity.
        attr_reader :element_name

        def initialize(element_name)
          @element_name = element_name
          super("content model is not deterministic: element " +                "#{element_name.inspect} matches more than one position")
        end
      end

      # Raised when a sequence of child elements does not match the
      # content model.
      class MismatchError < Error
        # Number of child elements consumed before the mismatch.
        attr_reader :position
        # The element name that did not match, or nil when the child
        # sequence ended before the model was satisfied.
        attr_reader :actual
        # Names of the elements allowed at the mismatch position.
        attr_reader :expected

        def initialize(position, actual, expected)
          @position = position
          @actual = actual
          @expected = expected
          detail = actual.nil? ? "end of children" : "element #{actual.inspect}"
          allowed = expected.empty? ? "nothing" : expected.map(&:inspect).join(" or ")
          super("content model mismatch at child #{position}: got " +                "#{detail}, expected #{allowed}")
        end
      end

      # Parses a content specification such as "EMPTY", "ANY",
      # "(#PCDATA|em)*" or "(a, (b|c)*, d?)" and returns a ContentModel.
      # Raises SyntaxError for malformed specifications and
      # AmbiguityError for non-deterministic element content models.
      def self.parse(spec)
        new(spec)
      end

      # One of :empty, :any, :mixed or :element.
      attr_reader :kind

      def initialize(spec)
        @spec = spec
        @tokens = tokenize(spec)
        @index = 0
        parse_spec
        unless @index == @tokens.length
          raise SyntaxError,
                "unexpected #{@tokens[@index].inspect} in content model #{spec.inspect}"
        end
        compile if @kind == :element
      end

      # The element names that may appear in valid content.  Empty for
      # EMPTY and ANY models.
      def names
        case @kind
        when :mixed
          @mixed_names.dup
        when :element
          @positions.uniq
        else
          []
        end
      end

      # Returns a new streaming validator for this model.  See
      # ContentModel::Validator.
      def validator
        Validator.new(self)
      end

      # Validates a sequence of child element names against this model.
      # Returns true when the sequence matches; raises MismatchError
      # (carrying #position, #actual and #expected) otherwise.
      def validate(children)
        validator = Validator.new(self)
        children.each do |name|
          unless validator.consume(name)
            raise MismatchError.new(validator.position, name, validator.expected)
          end
        end
        unless validator.finished?
          raise MismatchError.new(validator.position, nil, validator.expected)
        end
        true
      end

      # Whether a sequence of child element names matches this model.
      def valid?(children)
        validate(children)
        true
      rescue MismatchError
        false
      end

      # Consumes child element names one at a time.  Use #consume to
      # feed the next child, #expected to list the element names allowed
      # next, #position for the number of children consumed so far and
      # #finished? to check whether the model is satisfied.
      class Validator
        def initialize(model)
          @model = model
          reset
        end

        # Number of child elements consumed so far.
        attr_reader :position

        def reset
          @state = @model.start_state
          @position = 0
          self
        end

        # Feeds the next child element name.  Returns true when the
        # name is allowed at the current position, false otherwise.
        def consume(name)
          target = @model.transition(@state, name)
          return false unless target
          @state = target
          @position += 1
          true
        end

        # Names of the elements allowed at the current position.
        def expected
          @model.expected(@state)
        end

        # Whether the model is satisfied by the children consumed so
        # far.
        def finished?
          @model.accepting?(@state)
        end
      end

      # :stopdoc:
      START_STATE = [].freeze

      def start_state
        case @kind
        when :element then START_STATE
        else @kind
        end
      end

      def transition(state, name)
        case @kind
        when :any
          state
        when :mixed
          @mixed_names.include?(name) ? state : nil
        when :empty
          nil
        else
          @transitions[state][name]
        end
      end

      def expected(state)
        case @kind
        when :mixed
          @mixed_names.dup
        when :element
          @transitions[state].keys
        else
          []
        end
      end

      def accepting?(state)
        case @kind
        when :element
          @accepting[state]
        else
          true
        end
      end
      # :startdoc:

      private

      PUNCTUATION = ["(", ")", "|", ",", "?", "*", "+"].freeze

      def tokenize(spec)
        tokens = []
        rest = spec.to_s
        until rest.empty?
          case rest
          when /\A\s+/
            rest = $'
          when /\A[()|,?*+]/
            tokens << $&
            rest = $'
          when /\A[^\s()|,?*+]+/
            tokens << $&
            rest = $'
          end
        end
        tokens
      end

      def current_token
        @tokens[@index]
      end

      def advance
        @index += 1
      end

      def expect(token)
        unless current_token == token
          raise SyntaxError,
                "expected #{token.inspect} in content model #{@spec.inspect}"
        end
        advance
      end

      def name_token?(token)
        !token.nil? && !PUNCTUATION.include?(token)
      end

      def parse_spec
        case current_token
        when "EMPTY"
          advance
          @kind = :empty
        when "ANY"
          advance
          @kind = :any
        when "("
          advance
          if current_token == "#PCDATA"
            parse_mixed
          else
            @root = parse_group_body
            @kind = :element
          end
        else
          raise SyntaxError, "invalid content model #{@spec.inspect}"
        end
      end

      def parse_mixed
        advance # "#PCDATA"
        names = []
        while current_token == "|"
          advance
          name = current_token
          unless name_token?(name) && name != "#PCDATA"
            raise SyntaxError,
                  "expected element name in mixed content model #{@spec.inspect}"
          end
          if names.include?(name)
            raise SyntaxError,
                  "element #{name.inspect} appears more than once in " +                  "mixed content model #{@spec.inspect}"
          end
          names << name
          advance
        end
        expect(")")
        if names.empty?
          if PUNCTUATION[4..-1].include?(current_token)
            raise SyntaxError,
                  "(#PCDATA) must not have a quantifier in content model " +                  "#{@spec.inspect}"
          end
        else
          unless current_token == "*"
            raise SyntaxError,
                  "mixed content model with element names must be " +                  "followed by * in #{@spec.inspect}"
          end
          advance
        end
        @kind = :mixed
        @mixed_names = names
      end

      # Parses the inside of a "(...)" group in element content and the
      # group's optional quantifier.  The opening "(" is already
      # consumed.
      def parse_group_body
        children = [parse_particle]
        separator = nil
        loop do
          token = current_token
          if token == "," || token == "|"
            separator ||= token
            if token != separator
              raise SyntaxError,
                    "cannot mix #{separator.inspect} and #{token.inspect} " +                    "connectors in content model #{@spec.inspect}"
            end
            advance
            children << parse_particle
          elsif token == ")"
            advance
            break
          else
            raise SyntaxError,
                  "expected connector or ) in content model #{@spec.inspect}"
          end
        end
        node = separator == "|" ? [:choice, children] : [:sequence, children]
        apply_quantifier(node)
      end

      def parse_particle
        token = current_token
        if token == "("
          advance
          parse_group_body
        elsif name_token?(token) && token != "#PCDATA"
          advance
          apply_quantifier([:name, token])
        else
          raise SyntaxError,
                "expected element name or group in content model #{@spec.inspect}"
        end
      end

      def apply_quantifier(node)
        case current_token
        when "?"
          advance
          [:repeat, node, 0, 1]
        when "*"
          advance
          [:repeat, node, 0, nil]
        when "+"
          advance
          [:repeat, node, 1, nil]
        else
          node
        end
      end

      # Compiles the element content model into a deterministic
      # (Glushkov) automaton and verifies the XML determinism
      # constraint: from every reachable state, each element name may
      # lead to at most one position of the model.
      def compile
        @positions = []
        collect_positions(@root)
        follow = Array.new(@positions.size) { [] }
        compute_follow(@root, follow)
        last = lastpos(@root)
        root_nullable = nullable(@root)

        @transitions = {}
        @accepting = {START_STATE => root_nullable}
        queue = [START_STATE]
        seen = {START_STATE => true}
        until queue.empty?
          state = queue.shift
          candidates = state == START_STATE ? firstpos(@root) :
                       state.flat_map { |position| follow[position] }
          moves = {}
          candidates.each do |position|
            (moves[@positions[position]] ||= []) << position
          end
          transitions = {}
          moves.sort_by { |_, targets| targets.min }.each do |name, targets|
            targets.uniq!
            raise AmbiguityError.new(name) if targets.size > 1
            target = targets.sort.freeze
            transitions[name] = target
            unless seen[target]
              seen[target] = true
              @accepting[target] = target.any? { |position| last.include?(position) }
              queue << target
            end
          end
          @transitions[state] = transitions
        end
      end

      def collect_positions(node)
        case node[0]
        when :name
          node << @positions.size
          @positions << node[1]
        when :sequence, :choice
          node[1].each { |child| collect_positions(child) }
        when :repeat
          collect_positions(node[1])
        end
      end

      def nullable(node)
        case node[0]
        when :name
          false
        when :sequence
          node[1].all? { |child| nullable(child) }
        when :choice
          node[1].any? { |child| nullable(child) }
        when :repeat
          node[2] == 0 || nullable(node[1])
        end
      end

      def firstpos(node)
        case node[0]
        when :name
          [node[2]]
        when :sequence
          result = []
          node[1].each do |child|
            result.concat(firstpos(child))
            break unless nullable(child)
          end
          result
        when :choice
          node[1].flat_map { |child| firstpos(child) }
        when :repeat
          firstpos(node[1])
        end
      end

      def lastpos(node)
        case node[0]
        when :name
          [node[2]]
        when :sequence
          result = []
          node[1].reverse_each do |child|
            result.concat(lastpos(child))
            break unless nullable(child)
          end
          result
        when :choice
          node[1].flat_map { |child| lastpos(child) }
        when :repeat
          lastpos(node[1])
        end
      end

      def compute_follow(node, follow)
        case node[0]
        when :sequence
          children = node[1]
          children.each_with_index do |child, index|
            following = index + 1
            while following < children.length
              lastpos(child).each do |position|
                follow[position].concat(firstpos(children[following]))
              end
              break unless nullable(children[following])
              following += 1
            end
          end
          children.each { |child| compute_follow(child, follow) }
        when :choice
          node[1].each { |child| compute_follow(child, follow) }
        when :repeat
          if node[3].nil? || node[3] > 1
            lastpos(node[1]).each do |position|
              follow[position].concat(firstpos(node[1]))
            end
          end
          compute_follow(node[1], follow)
        end
      end
    end
  end
end
