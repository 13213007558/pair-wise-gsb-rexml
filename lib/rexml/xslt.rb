# frozen_string_literal: true

require_relative "document"
require_relative "xpath"
require_relative "cdata"

module REXML
  # A deliberately small XSLT 1.0 processor built on REXML.
  module XSLT
    XSL_NAMESPACE = "http://www.w3.org/1999/XSL/Transform"

    class Error < RuntimeError
    end

    def self.transform(source, stylesheet)
      Processor.new(stylesheet).apply(source)
    end
    class << self
      alias apply transform
    end

    Context = Struct.new(:node, :node_list, :position, :last, :variables, :mode) do
      def with(node:, node_list:, mode: self.mode)
        position = node_list.each_index.find { |index| node_list[index].equal?(node) } + 1
        Context.new(node, node_list, position, node_list.length, variables, mode)
      end

      def with_variables(variables)
        Context.new(node, node_list, position, last, variables, mode)
      end
    end

    Step = Struct.new(:axis, :kind, :prefix, :local_name, :target, :predicates, keyword_init: true)
    PatternAlternative = Struct.new(:steps, :absolute, :priority, keyword_init: true)

    class Pattern
      attr_reader :alternatives

      def initialize(alternatives)
        @alternatives = alternatives
      end

      def matches?(node, evaluator)
        @alternatives.any? { |alternative| alternative_matches?(alternative, node, evaluator) }
      end

      def priority
        @alternatives.first.priority
      end

      private

      def alternative_matches?(alternative, node, evaluator)
        chain = node_chain(node)
        return node.node_type == :document if alternative.steps.empty?
        return false unless alternative.absolute ? match_steps?(alternative.steps, chain, true, evaluator) :
          match_relative?(alternative.steps, chain, evaluator)
        true
      end

      def match_relative?(steps, chain, evaluator)
        return true if steps.empty?
        (chain.length - 1).downto(0).any? do |index|
          match_steps?(steps, chain[0..index], false, evaluator)
        end
      end

      def match_steps?(steps, chain, absolute, evaluator)
        return false if steps.length > chain.length

        step_index = steps.length - 1
        chain_index = chain.length - 1
        match_step_at?(steps, step_index, chain, chain_index, absolute, evaluator)
      end

      def match_step_at?(steps, step_index, chain, chain_index, absolute, evaluator)
        return chain_index == -1 if step_index < 0
        return false if chain_index < 0

        step = steps[step_index]
        if step.axis == :descendant
          chain.length.pred.downto(step_index).any? do |candidate|
            next false unless node_test_matches?(step, chain[candidate], evaluator)
            if step_index.zero?
              step_predicates_match?(step, chain[candidate], evaluator)
            else
              step_predicates_match?(step, chain[candidate], evaluator) &&
                match_step_at?(steps, step_index - 1, chain, candidate - 1, absolute, evaluator)
            end
          end
        else
          return false unless node_test_matches?(step, chain[chain_index], evaluator)
          return false unless step_predicates_match?(step, chain[chain_index], evaluator)
          match_step_at?(steps, step_index - 1, chain, chain_index - 1, absolute, evaluator)
        end
      end

      def node_test_matches?(step, node, evaluator)
        case step.kind
        when :any
          step.axis == :attribute ? node.node_type == :attribute : node.node_type == :element
        when :qname, :any_local_name
          return false unless node.node_type == (step.axis == :attribute ? :attribute : :element)
          if step.kind == :any_local_name
            node.name == step.local_name
          elsif step.prefix.nil?
            node.name == step.local_name && namespace_of(node) != ""
          else
            uri = step.prefix.empty? ? "" : evaluator.namespace_uri(node, step.prefix)
            node.name == step.local_name && namespace_of(node) == uri
          end
        when :namespace
          return node.node_type == :element || node.node_type == :attribute if step.local_name == :*
          node.node_type == (step.axis == :attribute ? :attribute : :element) &&
            node.name == step.local_name &&
            namespace_of(node) == evaluator.namespace_uri(node, step.prefix)
        when :text
          node.node_type == :text
        when :comment
          node.node_type == :comment
        when :processing_instruction
          node.node_type == :processing_instruction &&
            (step.target.nil? || node.target == step.target)
        when :node
          node.node_type == :element || node.node_type == :document ||
            node.node_type == :text || node.node_type == :comment ||
            node.node_type == :processing_instruction
        end
      end

      def step_predicates_match?(step, node, evaluator)
        list = predicate_list(node, step)
        position = list.index(node) + 1
        step.predicates.all? do |predicate|
          evaluator.truthy?(evaluator.evaluate_ast(predicate, node, list, position))
        end
      end

      def predicate_list(node, step)
        if node.node_type == :attribute
          node.element.attributes.each_attribute.to_a
        elsif node.node_type == :document
          [node]
        else
          parent = node.parent
          return [node] unless parent
          parent.children.select { |child| compatible_node?(child, step) }
        end
      end

      def compatible_node?(node, step)
        case step.kind
        when :text, :comment, :processing_instruction, :node
          node.node_type != :xmldecl
        else
          node.node_type == (step.axis == :attribute ? :attribute : :element)
        end
      end

      def namespace_of(node)
        node.node_type == :attribute ? node.namespace : node.namespace
      end

      def node_chain(node)
        if node.node_type == :attribute
          [node.element, node]
        elsif node.node_type == :document
          [node]
        else
          chain = []
          current = node
          while current
            chain << current
            current = current.parent
          end
          chain.reverse
        end
      end
    end

    class CompilingParser < REXML::Parsers::XPathParser
      def pattern(string)
        ast = parse(string)
        alternatives = split_union(ast).map { |alternative| compile_alternative(alternative) }
        priorities = alternatives.map(&:priority).uniq
        if priorities.length > 1
          raise Error, "union pattern alternatives must have equal default priority: #{string}"
        end
        Pattern.new(alternatives)
      end

      private

      def split_union(ast)
        return [ast] unless ast.is_a?(Array) && ast.first == :union
        ast[1..-1].flat_map { |part| split_union(part) }
      end

      def compile_alternative(ast)
        tokens = ast.dup
        absolute = false
        if tokens.first == :document
          absolute = true
          tokens.shift
        end
        raise Error, "unsupported match pattern" unless valid_start?(tokens)

        steps = []
        while tokens.any?
          if tokens.first == :descendant_or_self
            tokens.shift
            expect_token!(tokens, :node)
            unless tokens.empty?
              expect_token!(tokens, :child, :attribute)
              steps << read_step(tokens, :descendant)
            end
          elsif tokens.first == :child || tokens.first == :attribute
            axis = tokens.shift
            steps << read_step(tokens, axis)
          else
            raise Error, "unsupported match pattern"
          end
        end

        PatternAlternative.new(steps: steps, absolute: absolute, priority: default_priority(steps, absolute))
      end

      def valid_start?(tokens)
        tokens.empty? || tokens.first == :child || tokens.first == :attribute ||
          tokens.first == :descendant_or_self
      end

      def read_step(tokens, axis)
        kind = tokens.shift
        case kind
        when :any, :any_local_name, :namespace, :qname, :text,
             :comment, :processing_instruction, :node
          prefix = nil
          local_name = nil
          target = nil
          case kind
          when :qname
            raw_prefix = tokens.shift
            kind = :any_local_name if raw_prefix.nil?
            prefix = raw_prefix.to_s
            local_name = tokens.shift
          when :any_local_name
            prefix = nil
            local_name = tokens.shift
          when :namespace
            prefix = tokens.shift
            local_name = :*
          when :processing_instruction
            target_string = tokens.shift
            target = target_string.empty? ? nil : target_string
          end
          predicates = read_predicates(tokens)
          Step.new(
            axis: axis,
            kind: kind,
            prefix: prefix,
            local_name: local_name,
            target: target,
            predicates: predicates
          )
        else
          raise Error, "unsupported match pattern node test"
        end
      end

      def read_predicates(tokens)
        predicates = []
        while tokens.first == :predicate
          tokens.shift
          predicates << tokens.shift
        end
        predicates
      end

      def expect_token!(tokens, *expected)
        token = tokens.shift
        raise Error, "unsupported match pattern" unless expected.include?(token)
      end

      def default_priority(steps, _absolute)
        return 0.5 if steps.empty?
        last = steps.last
        return 0.5 if last.predicates.any? || steps.first.axis == :descendant ||
          (steps.length > 1 && steps[-2].axis == :descendant)
        case last.kind
        when :qname, :any_local_name
          0.0
        when :namespace
          -0.25
        when :any
          -0.5
        when :processing_instruction
          last.target.nil? ? -0.5 : 0.0
        else
          -0.5
        end
      end
    end

    class ContextualParser < REXML::XPathParser
      attr_accessor :xsl_context

      def expr(path_stack, nodeset, context = nil)
        super(path_stack, nodeset, context || xsl_context)
      end
    end

    class Evaluator
      attr_reader :namespace_map

      def initialize(source, namespace_map)
        @source = source
        @namespace_map = namespace_map || {}
        @grammar = REXML::Parsers::XPathParser.new
        @parser = ContextualParser.new(strict: true)
        @parser.namespaces = @namespace_map
      end

      def namespace_uri(node, prefix)
        if node.node_type == :attribute
          node.element.namespace(prefix) || ""
        else
          node.namespace(prefix) || ""
        end
      end

      def evaluate(expression, context)
        ast = parse_expression(expression)
        evaluate_ast(ast, context.node, context.node_list, context.position, context.variables)
      end

      def evaluate_ast(ast, node, node_list = [node], position = 1, variables = nil)
        variables ||= {}
        check_expression!(ast)
        @parser.variables = stringify_variables(variables)
        @parser.xsl_context = {
          node: node,
          position: position,
          size: node_list.length
        }
        result = @parser.send(:match, deep_dup(ast), node).then { |value| unwrap(value) }
        result = REXML::XPathParser.sort(result) if result.is_a?(Array)
        result
      end

      def select_nodes(expression, context)
        result = evaluate(expression, context)
        unless result.is_a?(Array) && result.all? { |value| value.respond_to?(:node_type) }
          raise Error, "select expression must return a node-set: #{expression}"
        end
        result
      end

      def truthy?(value)
        case value
        when Array
          value.any?
        when String
          !value.empty?
        when Numeric
          !value.zero?
        else
          !!value
        end
      end

      def string_value(value)
        case value
        when nil
          ""
        when true
          "true"
        when false
          "false"
        when Float, Integer
          @parser.instance_variable_get(:@functions).string(value)
        when String
          value
        when Array
          value.empty? ? "" : string_value(value.first)
        when REXML::Attribute
          value.value
        when REXML::Text
          value.value
        when REXML::Comment
          value.string
        when REXML::Instruction
          value.content.to_s
        when REXML::Document
          value.root ? string_value(value.root) : ""
        when REXML::Element
          element_string(value)
        else
          value.to_s
        end
      end

      private

      def parse_expression(expression)
        ast = @grammar.parse(expression.to_s)
        check_expression!(ast)
        ast
      end

      def check_expression!(ast)
        return unless ast.is_a?(Array)
        if ast.first == :function && (ast[1].to_s == "document" || ast[1].to_s.include?(":"))
          raise Error, "unsupported XPath function: #{ast[1]}"
        end
        ast.each { |part| check_expression!(part) }
      end

      def stringify_variables(variables)
        variables.each_with_object({}) do |(name, value), result|
          result[name] = string_value(value)
        end
      end

      def element_string(element)
        element.children.map do |child|
          case child.node_type
          when :text
            child.value
          when :element
            element_string(child)
          else
            ""
          end
        end.join
      end

      def unwrap(result)
        result.is_a?(Array) && result.length == 1 && !result.first.respond_to?(:node_type) ?
          result.first : result
      end

      def deep_dup(value)
        case value
        when Array
          value.map { |item| deep_dup(item) }
        when Symbol, Numeric, true, false, nil
          value
        else
          value.dup
        end
      end
    end

    class Processor
      Template = Struct.new(:node, :name, :mode, :pattern, :priority, :order, :params, keyword_init: true)
    end
  end
end
