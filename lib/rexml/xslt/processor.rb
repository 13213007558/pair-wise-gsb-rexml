# frozen_string_literal: true

require "rexml/document"
require "rexml/xpath"
require_relative "errors"
require_relative "stylesheet"

module REXML
  module XSLT
    # Executes a compiled Stylesheet against a source document.
    #
    # The processor is a tree-walking template engine, not a string
    # rewriter: source nodes are matched against template rules, the
    # winning rule's body is interpreted as a sequence constructor, and
    # literal result elements are cloned into a result tree which is
    # serialized at the end.
    #
    # Template rule conflict resolution (XSLT 1.0 section 5.5):
    #   1. highest import precedence wins;
    #   2. then highest priority (explicit xsl:template/@priority, or the
    #      default priority derived from the pattern);
    #   3. then the template that appears last in document order wins
    #      (the recovery behaviour allowed by the spec).
    # When no rule matches, the XSLT 1.0 built-in template rules apply
    # (section 5.8).
    #
    # Every selection -- user rule or built-in -- is recorded in
    # #trace_log as a human-readable explanation listing all candidates
    # and the reason the winner won.
    class Processor
      # A template rule that matched a node, together with the data used
      # to rank it.
      class Candidate
        attr_reader :template, :alternative, :priority

        def initialize(template, alternative, priority)
          @template = template
          @alternative = alternative
          @priority = priority
        end
      end

      # Human-readable explanations of every template selection made
      # during the last #transform call (Array of String).
      attr_reader :trace_log

      # +stylesheet+ is a compiled REXML::XSLT::Stylesheet.  +params+
      # overrides the defaults of top-level xsl:param declarations; keys
      # are parameter names (String or Symbol), values are Strings,
      # Numerics, Booleans or Arrays of REXML nodes.
      def initialize(stylesheet, params: {})
        @stylesheet = stylesheet
        @external_params = params
        @trace_log = []
      end

      # Transforms +source+ (an XML String or a REXML::Document) and
      # returns the serialized result tree as a String.
      def transform(source)
        document =
          begin
            source.is_a?(REXML::Document) ? source : REXML::Document.new(source)
          rescue REXML::ParseException => error
            raise EvaluationError, "cannot parse source document: #{error.message}"
          end
        @trace_log = []
        @global_variables = {}
        external = {}
        @external_params.each_key { |key| external[key.to_s] = @external_params[key] }
        @stylesheet.global_params.each do |name, select|
          @global_variables[name] =
            if external.key?(name)
              external[name]
            elsif select
              evaluate_value(select, document, @global_variables, nil)
            else
              ""
            end
        end

        # The result of a transformation is a node list, not necessarily
        # a well-formed document (it may have several element roots or
        # consist of text only), so output is collected in a plain
        # container element that is never serialized itself.
        result = REXML::Element.new("xsl:result")
        apply_templates([document], nil, {}, result)
        result.children.map(&:to_s).join
      end

      private

      # -- template selection ------------------------------------------

      def apply_templates(nodes, mode, params, out)
        nodes.each do |node|
          winner, candidates = select_template(node, mode)
          if winner
            trace_selection(node, mode, candidates, winner)
            execute_template(winner.template, node, mode, params, out)
          else
            trace_builtin(node, mode)
            execute_builtin(node, mode, out)
          end
        end
      end

      def select_template(node, mode)
        candidates = []
        @stylesheet.rules.each do |rule|
          next unless rule.mode == mode
          alternative = rule.pattern.matching_alternative(node)
          next unless alternative
          candidates << Candidate.new(rule, alternative, rule.priority_for(alternative))
        end
        return [nil, candidates] if candidates.empty?
        winner = candidates.max_by do |candidate|
          [candidate.template.precedence, candidate.priority, candidate.template.sequence]
        end
        [winner, candidates]
      end

      # -- template execution ------------------------------------------

      def execute_template(template, context_node, mode, params, out)
        variables = @global_variables.dup
        template.parameters.each do |param|
          variables[param.name] =
            if params.key?(param.name)
              params[param.name]
            elsif param.select
              evaluate_value(param.select, context_node, variables, template.element)
            else
              ""
            end
        end
        execute_body(template.element, context_node, mode, variables, out)
      end

      def execute_body(element, context_node, mode, variables, out)
        element.children.each do |child|
          case child
          when REXML::Text
            # Whitespace-only text nodes in the stylesheet are stripped
            # (XSLT 1.0 section 3.4); use xsl:text for significant
            # whitespace.
            out.add_text(child.value) unless child.value.strip.empty?
          when REXML::Element
            if child.namespace.to_s == NAMESPACE
              execute_instruction(child, context_node, mode, variables, out)
            else
              execute_literal_element(child, context_node, mode, variables, out)
            end
          end
        end
      end

      def execute_instruction(element, context_node, mode, variables, out)
        case element.name
        when "param"
          # Already bound by execute_template.
        when "value-of"
          select = element.attributes["select"]
          value = evaluate_value(select, context_node, variables, element)
          out.add_text(string_of(value))
        when "apply-templates"
          select = element.attributes["select"] || "node()"
          nodes = evaluate_xpath(select, context_node, variables, element)
          unless nodes.is_a?(Array) && nodes.all? { |n| n.respond_to?(:node_type) }
            raise EvaluationError,
                  "select expression #{select.inspect} of xsl:apply-templates " \
                  "must evaluate to a node-set"
          end
          new_mode = mode
          if (mode_lexical = element.attributes["mode"])
            new_mode = XSLT.expand_qname(mode_lexical, element.namespaces,
                                         error_class: EvaluationError)
          end
          params = evaluate_with_params(element, context_node, variables)
          apply_templates(nodes, new_mode, params, out)
        when "call-template"
          name = element.attributes["name"]
          key = XSLT.expand_qname(name, element.namespaces, error_class: EvaluationError)
          template = @stylesheet.named_templates[key] or
            raise EvaluationError, "no template named #{name.inspect}"
          params = evaluate_with_params(element, context_node, variables)
          execute_template(template, context_node, mode, params, out)
        when "text"
          buffer = +""
          element.children.each do |child|
            buffer << child.value if child.is_a?(REXML::Text)
          end
          out.add_text(buffer)
        else
          # Unreachable: compilation rejects unsupported instructions.
          raise EvaluationError, "unsupported instruction xsl:#{element.name}"
        end
      end

      def execute_literal_element(element, context_node, mode, variables, out)
        copy = element.deep_clone
        copy.children.to_a.each { |child| copy.delete(child) }
        # Attributes in the XSLT namespace (e.g. xsl:version on a literal
        # result element used as a stylesheet) are not copied.
        xsl_attributes = []
        copy.attributes.each_attribute do |attribute|
          xsl_attributes << attribute.expanded_name if attribute.namespace.to_s == NAMESPACE
        end
        xsl_attributes.each { |name| copy.delete_attribute(name) }
        out << copy
        execute_body(element, context_node, mode, variables, copy)
      end

      def evaluate_with_params(element, context_node, variables)
        params = {}
        element.each_element do |child| # only xsl:with-param; validated at compile time
          name = child.attributes["name"]
          select = child.attributes["select"]
          params[name] =
            select ? evaluate_value(select, context_node, variables, child) : ""
        end
        params
      end

      # -- built-in template rules (XSLT 1.0 section 5.8) ---------------

      def execute_builtin(node, mode, out)
        case node
        when REXML::Document, REXML::Element
          apply_templates(node.children.to_a, mode, {}, out)
        when REXML::Text
          out.add_text(node.value)
        when REXML::Attribute
          out.add_text(node.value)
        when REXML::Comment, REXML::Instruction
          # Discarded by the built-in rule.
        end
      end

      # -- XPath evaluation ---------------------------------------------

      def evaluate_xpath(select, context_node, variables, element)
        namespaces = element ? element.namespaces : {}
        REXML::XPath.match(context_node, select, namespaces, variables)
      rescue REXML::ParseException, REXML::UndefinedNamespaceException => error
        raise EvaluationError, "error evaluating #{select.inspect}: #{error.message}"
      end

      # Evaluates a select expression and normalizes the result the way
      # XSLT binds values: node-sets stay Arrays, everything else is a
      # scalar.
      def evaluate_value(select, context_node, variables, element)
        normalize_xpath_result(evaluate_xpath(select, context_node, variables, element))
      end

      def normalize_xpath_result(result)
        return result unless result.is_a?(Array)
        return result if result.all? { |item| item.respond_to?(:node_type) }
        result.length == 1 ? result[0] : result
      end

      # -- string conversion (XSLT 1.0 section 4.2, 11.1) ---------------

      def string_of(value)
        case value
        when Array
          value.empty? ? "" : string_value(value.first)
        when REXML::Node
          string_value(value)
        when Numeric
          format_number(value)
        when true then "true"
        when false then "false"
        when nil then ""
        else value.to_s
        end
      end

      def string_value(node)
        case node
        when REXML::Document
          node.root ? string_value(node.root) : ""
        when REXML::Element
          buffer = +""
          collect_text(node, buffer)
          buffer
        when REXML::Attribute then node.value
        when REXML::Text then node.value
        when REXML::Comment then node.string.to_s
        when REXML::Instruction then node.content.to_s
        else node.to_s
        end
      end

      def collect_text(element, buffer)
        element.children.each do |child|
          case child
          when REXML::Text then buffer << child.value
          when REXML::Element then collect_text(child, buffer)
          end
        end
      end

      def format_number(number)
        if number.is_a?(Float)
          return "NaN" if number.nan?
          return "Infinity" if number.infinite? == 1
          return "-Infinity" if number.infinite? == -1
          return number.to_i.to_s if number == number.to_i
        end
        number.to_s
      end

      # -- trace ---------------------------------------------------------

      def trace_selection(node, mode, candidates, winner)
        lines = []
        lines << "template selection for #{describe_node(node)} (#{describe_mode(mode)}): " \
                 "#{candidates.size} candidate rule(s)"
        sorted = candidates.sort_by do |candidate|
          [-candidate.template.precedence, -candidate.priority, candidate.template.sequence]
        end
        sorted.each do |candidate|
          rule = candidate.template
          lines << "  candidate #{rule.description} " \
                   "precedence=#{rule.precedence} " \
                   "priority=#{format_priority(candidate.priority)}"
        end
        lines << "  => selected #{winner.template.description}: " \
                 "#{selection_reason(winner, candidates)}"
        @trace_log << lines.join("\n")
      end

      def trace_builtin(node, mode)
        rule, action =
          case node
          when REXML::Document, REXML::Element
            ["for the root node and elements",
             "children are processed with xsl:apply-templates in the same mode"]
          when REXML::Text
            ["for text nodes", "the text is copied to the result tree"]
          when REXML::Attribute
            ["for attributes", "the attribute value is copied to the result tree"]
          else
            ["for comments and processing instructions", "nothing is emitted"]
          end
        @trace_log <<
          "template selection for #{describe_node(node)} (#{describe_mode(mode)}): " \
          "no template rule matches\n" \
          "  => built-in template rule #{rule} applies (#{action})"
      end

      def selection_reason(winner, candidates)
        rule = winner.template
        same_precedence = candidates.select { |c| c.template.precedence == rule.precedence }
        if same_precedence.size == 1
          return "highest import precedence (#{rule.precedence})"
        end
        same_priority = same_precedence.select { |c| c.priority == winner.priority }
        if same_priority.size == 1
          return "equal import precedence (#{rule.precedence}); " \
                 "highest priority (#{format_priority(winner.priority)})"
        end
        "equal import precedence (#{rule.precedence}) and priority " \
        "(#{format_priority(winner.priority)}); " \
        "latest in document order wins (template ##{rule.sequence} in #{rule.module_uri})"
      end

      def describe_node(node)
        case node
        when REXML::Document then "the root node"
        when REXML::Element then "element <#{node.expanded_name}>"
        when REXML::Attribute then "attribute @#{node.expanded_name}"
        when REXML::Text
          snippet = node.value.strip
          snippet = snippet[0, 20] + "..." if snippet.length > 20
          "text #{snippet.inspect}"
        when REXML::Comment then "a comment"
        when REXML::Instruction then "processing-instruction <?#{node.target}?>"
        else node.class.name
        end
      end

      def describe_mode(mode)
        mode.nil? ? "mode: #default" : "mode: #{mode}"
      end

      def format_priority(priority)
        priority == priority.to_i ? priority.to_i.to_s : priority.to_s
      end
    end
  end
end
