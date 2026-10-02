# frozen_string_literal: false
require_relative "../namespace"
require_relative "../parseexception"
require_relative "../streamlistener"
require_relative "../parsers/xpathparser"
require_relative "../parsers/streamparser"

module REXML
  class XPath
    # A lightweight element yielded by streaming XPath queries.  Unlike
    # REXML::Element, it does not keep child nodes or a parent reference.
    class StreamElement
      attr_reader :name, :attributes, :namespace, :prefix, :local_name

      def initialize(name, attributes, namespace)
        @name = name
        @attributes = attributes
        @namespace = namespace
        name =~ Namespace::NAMESPLIT
        @prefix = $1 || ""
        @local_name = $2
      end

      def attribute(name)
        @attributes[name]
      end

      def [](name)
        @attributes[name]
      end
    end

    # Evaluates a restricted element XPath while XML is being streamed.
    #
    # Supported location paths are:
    # - absolute or relative paths using child::, abbreviated child steps,
    #   descendant::, and abbreviated // steps,
    # - element name tests: QName, *, prefix:*, and *:local-name,
    # - attribute existence, and = or != comparisons against literals,
    # - predicates joined with and,
    # - position() with integer literals, + and -,
    # - last() in the final step, with integer literals, + and -,
    # - chained predicates such as a[@id][1].
    #
    # Other XPath constructs are rejected before input is read. The parser
    # builds no DOM. It keeps state for open elements, and a final step using
    # last() caches only lightweight candidates until the context closes.
    class Stream
      include StreamListener

      Step = Struct.new(:axis, :prefix, :local_name, :predicates) do
        def deferred?
          predicates.any? { |predicate| Stream.uses_last?(predicate) }
        end
      end

      Frame = Struct.new(:name, :namespaces, :states,
                         :descendant_states, :emitted) do
        def initialize(name, namespaces)
          states = Hash.new { |hash, key| hash[key] = [] }
          descendant_states = Hash.new { |hash, key| hash[key] = [] }
          super(name, namespaces, states, descendant_states, false)
        end

        def namespace_for(prefix)
          namespaces[prefix] || ""
        end
      end

      MatchState = Struct.new(:frame, :step_index, :positions,
                              :stage_positions, :candidates, :self_context,
                              :global_document_context) do
        def initialize(frame, step_index)
          super(frame, step_index, Hash.new(0),
                Hash.new { |hash, key| hash[key] = Hash.new(0) }, {}, false,
                false)
        end
      end
      Candidate = Struct.new(:state, :frame, :element)

      def self.uses_last?(expression)
        case expression
        when Array
          (expression.first == :function && expression[1] == "last") ||
          expression.any? do |item|
            item == :last || (item.is_a?(Array) && uses_last?(item))
          end
        else
          false
        end
      end

      def initialize(path, namespaces=nil)
        unless namespaces.nil? || namespaces.is_a?(Hash)
          raise ArgumentError, "namespaces must be a Hash or nil"
        end
        @path = path
        @namespaces = namespaces
        @tokens = REXML::Parsers::XPathParser.new.parse(path.to_s)
        @absolute = @tokens.first == :document
        @steps = compile
        reset
      end

      attr_reader :steps
      def active_frames
        @stack.size
      end

      def parse(source, &block)
        @block = block
        REXML::Parsers::StreamParser.new(source, self).parse
      ensure
        reset
      end

      def tag_start(name, attributes)
        parent = @stack.last || @root
        namespaces = parent.namespaces.dup
        attributes.each do |attribute_name, value|
          if attribute_name == "xmlns"
            namespaces[""] = value
          elsif attribute_name.start_with?("xmlns:")
            namespaces[attribute_name[6..-1]] = value
          end
        end

        frame = Frame.new(name, namespaces)
        propagate_states(parent, frame)
        @stack << frame
        add_abbreviated_context(frame)
        process_element(frame, attributes)
      end

      def tag_end(name)
        frame = @stack.pop
        flush_candidates(frame)
        flush_candidates(@root) if @stack.empty?
      end

      def close
        reset
      end

      private
      def reset
        @root = Frame.new(nil, {})
        add_document_context(@root)
        @stack = []
        @block = nil
      end

      def compile
        tokens = @tokens.dup
        tokens.shift if tokens.first == :document
        steps = []

        until tokens.empty?
          steps << compile_step(tokens, steps.last)
        end

        reject("an empty location path") if steps.empty?
        steps.each_with_index do |step, index|
          next unless step.deferred?
          if index != steps.size - 1
            reject("last() is only supported in the final step")
          end
        end
        steps
      end

      def compile_step(tokens, previous_step)
        axis = tokens.shift
        if axis == :descendant_or_self
          expect_token(tokens.shift, :node)
          expect_token(tokens.shift, :child)
          axis = :abbreviated_descendant
        end
        axis = :initial_descendant if axis == :descendant && previous_step.nil?
        if axis == :abbreviated_descendant && previous_step.nil?
          axis = :initial_abbreviated_descendant
        end
        unless axis == :child || axis == :descendant ||
               axis == :initial_descendant ||
               axis == :abbreviated_descendant ||
               axis == :initial_abbreviated_descendant
          reject("the #{axis.inspect} axis")
        end

        kind = tokens.shift
        case kind
        when :any
          prefix = :any
          local_name = nil
        when :qname
          prefix = tokens.shift
          local_name = tokens.shift
        when :namespace
          prefix = tokens.shift
          local_name = nil
        else
          reject("node test #{kind.inspect}")
        end

        predicates = []
        while tokens.first == :predicate
          tokens.shift
          predicates << compile_predicate(tokens.shift)
        end

        unless tokens.empty? ||
               [:child, :descendant_or_self].include?(tokens.first)
          reject("unsupported expression after step")
        end

        Step.new(axis, prefix, local_name, predicates)
      end

      def compile_predicate(expression)
        if expression.is_a?(Array) && expression.first == :literal &&
           expression[1].is_a?(Numeric)
          [:position_eq, [:number, compile_number(expression[1])]]
        elsif arithmetic_predicate?(expression)
          [:position_eq, compile_arithmetic(expression)]
        elsif expression == [:function, "last", []]
          [:position_eq, [:last]]
        elsif attribute_expression?(expression)
          prefix = expression[2] || ""
          local_name = expression[3]
          [:attribute_exists, [prefix, local_name]]
        elsif numeric_comparison?(expression.first)
          compile_comparison_predicate(expression)
        elsif expression.first == :and
          [:all, [compile_predicate(expression[1]),
                  compile_predicate(expression[2])]]
        else
          reject("unsupported predicate #{expression.inspect}")
        end
      end

      def attribute_expression?(expression)
        expression.is_a?(Array) && expression[0..1] == [:attribute, :qname] &&
          expression[2].is_a?(String) &&
          expression[3].is_a?(String)
      end

      def compile_comparison_predicate(expression)
        operator = expression[0]
        reject("unsupported comparison") unless numeric_comparison?(operator)

        if [:eq, :neq].include?(operator) &&
           attribute_expression?(expression[1]) &&
           literal_expression?(expression[2])
          prefix = expression[1][2] || ""
          local_name = expression[1][3]
          value = normalize_literal(expression[2][1])
          [:attribute_compare, [prefix, local_name], operator, value]
        elsif [:eq, :neq].include?(operator) &&
              literal_expression?(expression[1]) &&
              attribute_expression?(expression[2])
          prefix = expression[2][2] || ""
          local_name = expression[2][3]
          value = normalize_literal(expression[1][1])
          [:attribute_compare, [prefix, local_name],
           reverse_operator(operator), value]
        elsif arithmetic_expression?(expression[1]) &&
              arithmetic_expression?(expression[2])
          [:numeric_compare, operator,
           compile_arithmetic(expression[1]),
           compile_arithmetic(expression[2])]
        else
          reject("unsupported comparison #{expression.inspect}")
        end
      end

      def literal_expression?(expression)
        expression.is_a?(Array) && expression.first == :literal
      end

      def arithmetic_predicate?(expression)
        arithmetic_expression?(expression) && Stream.uses_last?(expression)
      end

      def arithmetic_expression?(expression)
        expression == [:function, "position", []] ||
          expression == [:function, "last", []] ||
          expression == :last || expression == :position ||
          (expression.is_a?(Array) && expression.first == :literal &&
           expression[1].is_a?(Numeric)) ||
          (expression.is_a?(Array) && expression.first == :neg &&
           arithmetic_expression?(expression[1])) ||
          (expression.is_a?(Array) &&
           [:plus, :minus].include?(expression.first) &&
           arithmetic_expression?(expression[1]) &&
           arithmetic_expression?(expression[2]))
      end

      def compile_arithmetic(expression)
        if expression == [:function, "position", []]
          [:position]
        elsif expression == [:function, "last", []]
          [:last]
        elsif expression.is_a?(Array) && expression.first == :literal &&
              expression[1].is_a?(Numeric)
          [:number, compile_number(expression[1])]
        elsif expression.is_a?(Array) && expression.first == :neg
          [:minus, [:number, 0], compile_arithmetic(expression[1])]
        elsif expression.is_a?(Array) &&
              [:plus, :minus].include?(expression.first)
          [expression.first, compile_arithmetic(expression[1]),
           compile_arithmetic(expression[2])]
        else
          reject("unsupported position expression #{expression.inspect}")
        end
      end

      def numeric_comparison?(operator)
        [:eq, :neq, :lt, :lteq, :gt, :gteq].include?(operator)
      end

      def reverse_operator(operator)
        {lt: :gt, lteq: :gteq, gt: :lt, gteq: :lteq}.fetch(operator, operator)
      end

      def expect_token(actual, expected)
        reject("expected #{expected.inspect}") unless actual == expected
      end

      def normalize_literal(value)
        value.is_a?(Numeric) ? compile_number(value) : value
      end

      def compile_number(value)
        value.to_f == value.to_i.to_f ? value.to_i : value.to_f
      end

      def reject(message)
        raise ParseException.new(
          "Unsupported streaming XPath: #{message}: <#{@path}>"
        )
      end

      def add_document_context(frame)
        state = MatchState.new(frame, -1)
        state.self_context = true
        state.global_document_context = frame.equal?(@root)
        frame.descendant_states[-1] << state
        state
      end

      def add_abbreviated_context(frame)
        return if frame.equal?(@root)
        state = MatchState.new(frame, -1)
        frame.descendant_states[-1] << state
        state
      end

      def propagate_states(parent, child)
        parent.descendant_states.each do |step_index, states|
          states.each do |state|
            copied = state
            if state.global_document_context
              child.descendant_states[step_index] << state
            elsif !state.self_context
              child.descendant_states[step_index] << copied
            end
          end
        end
        parent.states.each do |step_index, states|
          states.each do |state|
            child.descendant_states[step_index] << state
            context = copy_state(state)
            context.self_context = false
            child.descendant_states[step_index] << context
          end
        end
      end

      def copy_state(state)
        MatchState.new(state.frame, state.step_index).tap do |copy|
          copy.positions.replace(state.positions)
          state.stage_positions.each do |key, counts|
            copy.stage_positions[key] = counts.dup
          end
        end
      end

      def process_element(frame, attributes)
        @steps.each_with_index do |step, step_index|
          next unless matches_name?(step, frame)

          source_states(frame, step, step_index).each do |source_state|
            base_position = source_state.positions[step_index]
            source_state.positions[step_index] += 1
            stage_positions = source_state.stage_positions[step_index]
            state = MatchState.new(frame, step_index)

            if final_step?(step_index)
              if step.deferred?
                add_candidate(source_state, state, frame, attributes)
              elsif predicates_pass?(step, frame, attributes,
                                   base_position, stage_positions)
                emit_element(frame, attributes)
              end
            elsif predicates_pass?(step, frame, attributes,
                                   base_position, stage_positions)
              frame.states[step_index] << state
            end
          end
        end
      end

      def source_states(frame, step, step_index)
        case step.axis
        when :initial_descendant
          frame.descendant_states[-1].select(&:global_document_context)
        when :initial_abbreviated_descendant
          frame.descendant_states[-1].select do |state|
            (state.global_document_context && frame.equal?(@stack.first)) ||
              (!state.global_document_context && state.frame == @stack[-2] &&
                !state.frame.equal?(@root))
          end
        when :child
          parent = @stack[-2] || @root
          if step_index.zero?
            if @absolute
              frame.descendant_states[-1].select(&:global_document_context)
            else
              frame.descendant_states[-1].select do |state|
                state.global_document_context &&
                  state.frame == parent
              end
            end
          else
            parent.states[step_index - 1]
          end
        when :descendant
          frame.descendant_states[step_index - 1]
        when :abbreviated_descendant
          frame.descendant_states[step_index - 1].select do |state|
            !state.self_context || state.frame != frame
          end
        else
          []
        end
      end

      def predicates_pass?(step, frame, attributes,
                            base_position, stage_positions)
        position = base_position
        step.predicates.all? do |predicate|
          result = evaluate_predicate(predicate, frame, attributes,
                                      position, nil)
          next false unless result
          position = stage_positions.fetch(predicate, 0)
          stage_positions[predicate] = position + 1
          true
        end
      end

      def evaluate_predicate(predicate, frame, attributes, position, last)
        type = predicate.first
        if type == :all
          predicate[1].all? do |child|
            evaluate_predicate(child, frame, attributes, position, last)
          end
        elsif type == :position_eq
          evaluate_arithmetic(predicate[1], position, last) == position + 1
        elsif type == :numeric_compare
          compare(evaluate_arithmetic(predicate[2], position, last),
                  predicate[1],
                  evaluate_arithmetic(predicate[3], position, last))
        elsif type == :attribute_exists
          !attribute_value(frame, attributes, predicate[1]).nil?
        elsif type == :attribute_compare
          actual = attribute_value(frame, attributes, predicate[1])
          !actual.nil? &&
            compare_strings(actual.to_s, predicate[2], predicate[3])
        else
          false
        end
      end

      def compare(left, operator, right)
        return false if left.nil? || right.nil?
        if left.is_a?(String) || right.is_a?(String)
          left = left.to_s
          right = right.to_s
        end
        left.public_send(operator_map(operator), right)
      end

      def operator_map(operator)
        {eq: :==, neq: :!=, lt: :<, lteq: :<=, gt: :>, gteq: :>=}.fetch(operator)
      end

      def compare_strings(left, operator, right)
        left.public_send(operator_map(operator), right.to_s)
      end

      def evaluate_arithmetic(expression, position, last)
        type = expression.first
        if type == :position
          position + 1
        elsif type == :last
          last
        elsif type == :number
          expression[1]
        elsif [:plus, :minus].include?(type)
          operator = type == :plus ? :+ : :-
          evaluate_arithmetic(expression[1], position, last).public_send(
            operator,
            evaluate_arithmetic(expression[2], position, last)
          )
        end
      end

      def add_candidate(source_state, state, frame, attributes)
        element = StreamElement.new(frame.name, attributes.dup,
                                   element_namespace(frame))
        candidate = Candidate.new(state, frame, element)
        source_state.candidates[state.step_index] ||= []
        source_state.candidates[state.step_index] << candidate
      end

      def flush_candidates(source_frame)
        states = source_frame.states.values.flatten
        states.concat(source_frame.descendant_states.values.flatten.select do |state|
          state.frame.equal?(source_frame) ||
            (!state.frame.equal?(source_frame) &&
              !state.global_document_context &&
              state.step_index >= 0 &&
              !state.frame.states[state.step_index].include?(state) &&
              source_frame.descendant_states[state.step_index].include?(state))
        end)
        states.uniq!
        states.each do |source_state|
          source_state.candidates.each do |step_index, candidates|
            step = @steps[step_index]
            selected = candidates
            step.predicates.each do |predicate|
              last = selected.size
              selected = selected.select.with_index do |candidate, index|
                evaluate_predicate(predicate, candidate.frame,
                                   candidate.element.attributes, index, last)
              end
            end
            selected.each { |candidate| emit_candidate(candidate) }
          end
        end
      end

      def emit_candidate(candidate)
        return if candidate.frame.emitted
        candidate.frame.emitted = true
        @block.call(candidate.element)
      end

      def emit_element(frame, attributes)
        return if frame.emitted
        frame.emitted = true
        @block.call(StreamElement.new(frame.name, attributes.dup,
                                      element_namespace(frame)))
      end

      def final_step?(step_index)
        step_index == @steps.size - 1
      end

      def matches_name?(step, frame)
        frame.name =~ Namespace::NAMESPLIT
        prefix = $1 || ""
        local_name = $2
        return false unless step.local_name.nil? || local_name == step.local_name
        return true if step.prefix == :any || step.prefix.nil?
        return frame.namespace_for(prefix).empty? if step.prefix.empty?

        expected_namespace(step.prefix, frame) == frame.namespace_for(prefix)
      end

      def element_namespace(frame)
        frame.name =~ Namespace::NAMESPLIT
        frame.namespace_for($1 || "")
      end

      def expected_namespace(prefix, frame)
        return @namespaces.fetch(prefix, frame.namespace_for(prefix)) if @namespaces
        frame.namespace_for(prefix)
      end

      def attribute_value(frame, attributes, attribute)
        prefix, local_name = attribute
        return attributes[local_name] if prefix.empty?

        name = "#{prefix}:#{local_name}"
        return attributes[name] if attributes.key?(name)

        uri = expected_namespace(prefix, frame)
        attributes.each do |attribute_name, value|
          attribute_name =~ Namespace::NAMESPLIT
          next unless $2 == local_name
          attribute_prefix = $1 || ""
          next if attribute_prefix.empty?
          return value if frame.namespace_for(attribute_prefix) == uri
        end
        nil
      end
    end
  end
end
