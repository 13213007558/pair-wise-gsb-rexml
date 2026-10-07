# frozen_string_literal: false

require_relative "document"
require_relative "xpath_parser"

module REXML
  # A deliberately scoped XSLT 1.0 executor built on top of REXML.
  #
  # The entry point is REXML::XSLT.transform (or XSLT::Transformer when one
  # stylesheet is applied to many sources).  It takes an already parsed
  # source document and an already parsed stylesheet, and returns a new
  # REXML::Document.  Neither input is modified.
  #
  # Supported, and intentionally nothing more:
  #
  # * +xsl:template+ with +match+, +name+, +mode+ and +priority+
  # * +xsl:apply-templates+ (+select+, +mode+, +xsl:with-param+)
  # * +xsl:call-template+ (+name+, +xsl:with-param+)
  # * +xsl:param+ / +xsl:with-param+, with their own per-template scope
  # * +xsl:value-of+, +xsl:for-each+, +xsl:if+,
  #   +xsl:choose+ / +xsl:when+ / +xsl:otherwise+
  # * literal result elements, including attribute value templates
  # * the standard built-in templates
  #
  # Match patterns are interpreted by a dedicated parser (XSLT::Pattern),
  # separate from the XPath engine used for +select+ and +test+
  # expressions.  When several templates match the same node, the XSLT
  # default priorities decide; remaining ties go to the template that
  # appears last in the stylesheet.  Only the winning template is
  # instantiated.  +position()+ and +last()+ always reflect the node list
  # currently being processed (the +xsl:apply-templates+ or
  # +xsl:for-each+ selection).
  #
  # Out of scope, and reported with REXML::XSLT::Error when encountered:
  # +xsl:import+ / +xsl:include+, +document()+, extension functions,
  # +xsl:variable+, +xsl:sort+, predicates in match patterns, and any
  # other instruction not listed above.  No claim of full XSLT 1.0
  # conformance is made.
  module XSLT
    # The XSLT 1.0 namespace URI.
    XSL_NAMESPACE = "http://www.w3.org/1999/XSL/Transform"

    # Raised when a stylesheet uses something outside of the supported
    # subset, or is otherwise invalid.
    class Error < StandardError; end

    # Transforms +source+ (a REXML::Document, or a REXML::Element used as
    # the initial node) with +stylesheet+ (a REXML::Document or the
    # xsl:stylesheet element) and returns a new REXML::Document.
    #
    # +params+ optionally supplies values for top level +xsl:param+
    # declarations, keyed by parameter name.
    def self.transform(source, stylesheet, params={})
      Transformer.new(stylesheet).transform(source, params)
    end

    # A parsed XSLT 1.0 match pattern, such as "item", "*", "s:entry",
    # "node()", "@id", "a/b" or "a//b".  Patterns are interpreted here,
    # not by the XPath engine: a pattern is matched against a node by
    # walking up from the node, never by selecting from the root.
    class Pattern
      # One step of a pattern.  +axis+ is :child or :attribute, +kind+ is
      # :root, :name, :wildcard, :ns_wildcard, :node, :text, :comment or
      # :pi, +name+ is the local name (or the literal of a
      # processing-instruction test) and +uri+ is the resolved namespace
      # URI of the step ("" for no namespace).
      Step = Struct.new(:axis, :kind, :name, :uri)

      NC_NAME = /[A-Za-z_][A-Za-z0-9_.\-]*/

      # Parses a match attribute value into a list of Pattern objects,
      # one per "|" alternative.  +namespaces+ maps prefixes to URIs as
      # declared in the stylesheet.
      def self.parse(source, namespaces)
        alternatives = split_top_level(source, "|").map(&:strip).reject(&:empty?)
        raise Error, "empty match pattern" if alternatives.empty?
        alternatives.map { |alternative| new(alternative, namespaces) }
      end

      def initialize(alternative, namespaces) # :nodoc:
        @steps = []
        @links = []
        pending_link = nil
        Pattern.tokenize(alternative).each do |type, value|
          if type == :separator
            if pending_link
              raise Error, "invalid match pattern: #{alternative.inspect}"
            end
            pending_link = value
          else
            if @steps.empty?
              if pending_link
                @steps << Step.new(:child, :root)
                @links << pending_link
              end
            else
              unless pending_link
                raise Error, "invalid match pattern: #{alternative.inspect}"
              end
              @links << pending_link
            end
            @steps << Pattern.parse_step(value, namespaces)
            pending_link = nil
          end
        end
        if pending_link
          unless @steps.empty?
            raise Error, "invalid match pattern: #{alternative.inspect}"
          end
          @steps << Step.new(:child, :root)
        end
        raise Error, "invalid match pattern: #{alternative.inspect}" if @steps.empty?
      end

      # Whether +node+ matches this pattern.
      def matches?(node)
        match_step(@steps.length - 1, node)
      end

      # The XSLT 1.0 default priority for this pattern.
      def default_priority
        if @steps.length == 1
          step = @steps.first
          case step.kind
          when :name
            0
          when :pi
            step.name ? 0 : -0.5
          when :wildcard, :ns_wildcard, :node, :text, :comment
            -0.5
          else
            0.5
          end
        else
          0.5
        end
      end

      # Splits +source+ on +delimiter+ characters that appear outside of
      # quotes and parentheses.
      def self.split_top_level(source, delimiter) # :nodoc:
        parts = []
        quote = nil
        depth = 0
        start = 0
        source.each_char.with_index do |char, index|
          if quote
            quote = nil if char == quote
          elsif char == "'" || char == '"'
            quote = char
          elsif char == "("
            depth += 1
          elsif char == ")"
            depth -= 1
          elsif char == delimiter && depth.zero?
            parts << source[start...index]
            start = index + 1
          end
        end
        parts << source[start..]
        parts
      end

      # Splits a single pattern alternative into [:step, String] and
      # [:separator, :child|:descendant] tokens.
      def self.tokenize(source) # :nodoc:
        tokens = []
        buffer = +""
        quote = nil
        depth = 0
        index = 0
        while index < source.length
          char = source[index]
          if quote
            buffer << char
            quote = nil if char == quote
          elsif char == "'" || char == '"'
            quote = char
            buffer << char
          elsif char == "("
            depth += 1
            buffer << char
          elsif char == ")"
            depth -= 1
            buffer << char
          elsif char == "/" && depth.zero?
            tokens << [:step, buffer] unless buffer.empty?
            buffer = +""
            if source[index + 1] == "/"
              tokens << [:separator, :descendant]
              index += 1
            else
              tokens << [:separator, :child]
            end
          else
            buffer << char
          end
          index += 1
        end
        tokens << [:step, buffer] unless buffer.empty?
        tokens
      end

      # Parses one step token such as "item", "@id", "*", "s:*" or
      # "text()" into a Step.
      def self.parse_step(token, namespaces) # :nodoc:
        token = token.strip
        axis = :child
        if token.start_with?("@")
          axis = :attribute
          token = token[1..]
        end
        if token.include?("[")
          raise Error, "predicates in match patterns are not supported: #{token.inspect}"
        end
        case token
        when "*"
          Step.new(axis, :wildcard)
        when "node()"
          Step.new(axis, :node)
        when "text()"
          Step.new(axis, :text)
        when "comment()"
          Step.new(axis, :comment)
        when /\Aprocessing-instruction\(\s*\)\z/
          Step.new(axis, :pi)
        when /\Aprocessing-instruction\(\s*(['"])(.*?)\1\s*\)\z/
          Step.new(axis, :pi, $2)
        when /\A(#{NC_NAME}):\*\z/
          Step.new(axis, :ns_wildcard, nil, resolve_prefix($1, namespaces))
        when /\A(#{NC_NAME}):(#{NC_NAME})\z/
          Step.new(axis, :name, $2, resolve_prefix($1, namespaces))
        when /\A#{NC_NAME}\z/
          Step.new(axis, :name, token, "")
        else
          raise Error, "unsupported match pattern step: #{token.inspect}"
        end
      end

      def self.resolve_prefix(prefix, namespaces) # :nodoc:
        uri = namespaces[prefix]
        unless uri
          raise Error, "unbound namespace prefix in match pattern: #{prefix.inspect}"
        end
        uri
      end

      private

      def match_step(index, node)
        return false unless step_matches?(@steps[index], node)
        return true if index.zero?
        link = @links[index - 1]
        parent = parent_of(node)
        return false unless parent
        if link == :child
          match_step(index - 1, parent)
        else
          while parent
            return true if match_step(index - 1, parent)
            parent = parent_of(parent)
          end
          false
        end
      end

      def parent_of(node)
        node.node_type == :attribute ? node.element : node.parent
      end

      def step_matches?(step, node)
        type = node.node_type
        case step.kind
        when :root
          type == :document
        when :node
          step.axis == :attribute ? type == :attribute : type != :attribute
        when :wildcard
          axis_type?(step.axis, type)
        when :ns_wildcard
          axis_type?(step.axis, type) && node.namespace.to_s == step.uri
        when :name
          axis_type?(step.axis, type) && node.name == step.name &&
            node.namespace.to_s == step.uri
        when :text
          type == :text
        when :comment
          type == :comment
        when :pi
          type == :processing_instruction &&
            (step.name.nil? || node.target == step.name)
        else
          false
        end
      end

      def axis_type?(axis, type)
        axis == :attribute ? type == :attribute : type == :element
      end
    end

    # A parsed xsl:template element.
    class Template
      # An xsl:param or xsl:with-param declaration: a name, an optional
      # XPath select expression, and the element whose children form the
      # default/content when no select is given.
      Param = Struct.new(:name, :select, :content)

      # The template name, or nil for a match-only template.
      attr_reader :name
      # The template mode, or nil.
      attr_reader :mode
      # The explicit or default priority used for conflict resolution.
      attr_reader :priority
      # The position of the template in the stylesheet, used to break
      # priority ties in favor of the later template.
      attr_reader :order
      # The xsl:param declarations of the template.
      attr_reader :params
      # The template body: the children after the leading xsl:param
      # elements.
      attr_reader :body

      def initialize(element, order, namespaces) # :nodoc:
        @order = order
        @name = element.attributes["name"]
        @name = nil if @name && @name.empty?
        @mode = element.attributes["mode"]
        @mode = nil if @mode && @mode.empty?
        match = element.attributes["match"]
        match = nil if match && match.empty?
        if match.nil? && @name.nil?
          raise Error, "xsl:template requires a match or a name attribute"
        end
        @patterns = match ? Pattern.parse(match, namespaces) : nil
        explicit = element.attributes["priority"]
        @priority =
          if explicit
            begin
              Float(explicit)
            rescue ArgumentError
              raise Error, "invalid xsl:template priority: #{explicit.inspect}"
            end
          elsif @patterns
            @patterns.map(&:default_priority).max
          end
        @params = []
        @body = []
        in_params = true
        element.children.each do |child|
          next if child.node_type == :comment
          next if child.node_type == :text && child.value.strip.empty?
          if in_params && Template.xsl_element_named?(child, "param")
            @params << Template.parse_param(child)
          else
            in_params = false
            if Template.xsl_element_named?(child, "param")
              raise Error, "xsl:param must precede the body of xsl:template"
            end
            @body << child
          end
        end
      end

      # Whether any of the template's patterns matches +node+.
      def matches?(node)
        @patterns.any? { |pattern| pattern.matches?(node) }
      end

      # Whether the template has a match pattern and therefore takes
      # part in xsl:apply-templates selection.
      def match_pattern?
        !@patterns.nil?
      end

      # Builds a Param from an xsl:param or xsl:with-param element.
      def self.parse_param(element) # :nodoc:
        name = element.attributes["name"]
        if name.nil? || name.empty?
          raise Error, "xsl:#{element.name} requires a name attribute"
        end
        Param.new(name, element.attributes["select"], element)
      end

      def self.xsl_element_named?(node, name) # :nodoc:
        node.node_type == :element &&
          node.namespace.to_s == XSL_NAMESPACE && node.name == name
      end
    end

    # Applies one parsed stylesheet to source documents.  See
    # REXML::XSLT for the supported subset.
    #
    #   transformer = REXML::XSLT::Transformer.new(stylesheet_document)
    #   result = transformer.transform(source_document)
    class Transformer
      # Matches a document() call in an XPath expression, avoiding
      # false positives on names such as "my-document(".
      DOCUMENT_FUNCTION = /(?<![\w.\-])document\s*\(/

      # The evaluation state while a template is instantiated: the
      # current node and its position and size within the node list
      # being processed, the current mode, the in-scope parameters, the
      # parameters passed to the template being entered, and the result
      # tree node output is appended to.
      Context = Struct.new(:node, :position, :size, :mode,
                           :variables, :params, :output,
                           keyword_init: true) do
        def derive(**changes)
          Context.new(**to_h.merge(changes))
        end
      end

      # +stylesheet+ is a REXML::Document or the xsl:stylesheet element.
      def initialize(stylesheet)
        root = stylesheet.is_a?(REXML::Document) ? stylesheet.root : stylesheet
        unless root && root.node_type == :element &&
               root.namespace.to_s == XSL_NAMESPACE &&
               (root.name == "stylesheet" || root.name == "transform")
          raise Error, "stylesheet root must be xsl:stylesheet or xsl:transform"
        end
        @namespaces = root.namespaces
        @templates = []
        @named_templates = {}
        @global_params = []
        order = 0
        root.children.each do |child|
          next if child.node_type == :comment
          next if child.node_type == :text && child.value.strip.empty?
          if xsl_element?(child)
            case child.name
            when "template"
              template = Template.new(child, order, @namespaces)
              order += 1
              @templates << template if template.match_pattern?
              if template.name
                if @named_templates.key?(template.name)
                  raise Error, "duplicate xsl:template name: #{template.name.inspect}"
                end
                @named_templates[template.name] = template
              end
            when "param"
              @global_params << Template.parse_param(child)
            else
              raise Error, "unsupported top-level XSLT element: xsl:#{child.name}"
            end
          elsif child.node_type == :element
            # User-defined top-level elements are allowed and ignored.
          else
            raise Error, "unexpected content in xsl:stylesheet: #{child.inspect}"
          end
        end
        @xpath = XPathParser.new
        @xpath.namespaces = @namespaces
      end

      # Transforms +source+ (a REXML::Document, or a REXML::Element used
      # as the initial node) and returns a new REXML::Document.  +params+
      # optionally overrides top level xsl:param defaults, keyed by
      # parameter name.
      def transform(source, params={})
        context = Context.new(node: source, position: 1, size: 1, mode: nil,
                              variables: {}, params: {}, output: nil)
        globals = {}
        @global_params.each do |param|
          globals[param.name] =
            if params.key?(param.name)
              params[param.name]
            else
              evaluate_param_default(param, context.derive(variables: globals.dup))
            end
        end
        result = REXML::Document.new
        apply_templates([source], nil, globals, {}, result)
        result
      end

      private

      def xsl_element?(node)
        node.node_type == :element && node.namespace.to_s == XSL_NAMESPACE
      end

      # Applies the best matching template (or the built-in template) to
      # every node of +nodes+, in document order, with position() and
      # last() reflecting the list.
      def apply_templates(nodes, mode, variables, params, output)
        list = nodes.to_a
        list.each_with_index do |node, index|
          context = Context.new(node: node, position: index + 1, size: list.size,
                                mode: mode, variables: variables,
                                params: params, output: output)
          template = find_template(node, mode)
          if template
            execute_template(template, context)
          else
            execute_builtin_template(context)
          end
        end
      end

      # The matching template with the highest priority; ties go to the
      # template that appears last in the stylesheet.
      def find_template(node, mode)
        best = nil
        @templates.each do |template|
          next unless template.mode == mode
          next unless template.matches?(node)
          if best.nil? ||
             template.priority > best.priority ||
             (template.priority == best.priority && template.order > best.order)
            best = template
          end
        end
        best
      end

      def execute_template(template, context)
        values = {}
        template.params.each do |param|
          values[param.name] =
            if context.params.key?(param.name)
              context.params[param.name]
            else
              evaluate_param_default(param, context.derive(variables: context.variables.merge(values)))
            end
        end
        execute_children(template.body,
                         context.derive(variables: context.variables.merge(values),
                                        params: {}))
      end

      # The standard built-in templates: elements and the root recurse
      # in the current mode, text and attribute nodes are copied as
      # text, comments and processing instructions produce nothing.
      def execute_builtin_template(context)
        node = context.node
        case node.node_type
        when :document, :element
          apply_templates(node.children, context.mode, context.variables,
                          {}, context.output)
        when :text, :attribute
          context.output.add_text(node.value)
        end
      end

      def execute_children(children, context)
        children.each do |child|
          case child.node_type
          when :text
            value = child.value
            context.output.add_text(value) unless value.strip.empty?
          when :element
            if xsl_element?(child)
              execute_instruction(child, context)
            else
              execute_literal_element(child, context)
            end
          end
        end
      end

      def execute_instruction(instruction, context)
        case instruction.name
        when "apply-templates"
          instruction_apply_templates(instruction, context)
        when "call-template"
          instruction_call_template(instruction, context)
        when "value-of"
          instruction_value_of(instruction, context)
        when "for-each"
          instruction_for_each(instruction, context)
        when "if"
          instruction_if(instruction, context)
        when "choose"
          instruction_choose(instruction, context)
        when "when", "otherwise", "with-param"
          raise Error, "xsl:#{instruction.name} is not allowed here"
        when "param"
          raise Error, "xsl:param must lead xsl:template or xsl:stylesheet"
        else
          raise Error, "unsupported XSLT instruction: xsl:#{instruction.name}"
        end
      end

      def instruction_apply_templates(instruction, context)
        select = instruction.attributes["select"] || "node()"
        mode = instruction.attributes["mode"]
        nodes = evaluate_expression(select, context)
        unless nodes.is_a?(Array)
          raise Error, "xsl:apply-templates select must be a node-set: #{select.inspect}"
        end
        params = evaluate_with_params(instruction, context)
        apply_templates(nodes, mode, context.variables, params, context.output)
      end

      def instruction_call_template(instruction, context)
        name = instruction.attributes["name"]
        if name.nil? || name.empty?
          raise Error, "xsl:call-template requires a name attribute"
        end
        template = @named_templates[name]
        raise Error, "no template named #{name.inspect}" unless template
        params = evaluate_with_params(instruction, context)
        execute_template(template, context.derive(params: params))
      end

      def instruction_value_of(instruction, context)
        select = required_attribute(instruction, "select")
        value = evaluate_expression(select, context)
        context.output.add_text(xpath_string(value))
      end

      def instruction_for_each(instruction, context)
        select = required_attribute(instruction, "select")
        nodes = evaluate_expression(select, context)
        unless nodes.is_a?(Array)
          raise Error, "xsl:for-each select must be a node-set: #{select.inspect}"
        end
        nodes.each_with_index do |node, index|
          execute_children(instruction.children,
                           context.derive(node: node, position: index + 1,
                                          size: nodes.size))
        end
      end

      def instruction_if(instruction, context)
        test = required_attribute(instruction, "test")
        if xpath_boolean(evaluate_expression(test, context))
          execute_children(instruction.children, context)
        end
      end

      def instruction_choose(instruction, context)
        matched = false
        instruction.children.each do |child|
          next if child.node_type == :text && child.value.strip.empty?
          unless xsl_element?(child) &&
                 (child.name == "when" || child.name == "otherwise")
            raise Error, "only xsl:when and xsl:otherwise are allowed in xsl:choose"
          end
          next if matched
          if child.name == "when"
            test = required_attribute(child, "test")
            if xpath_boolean(evaluate_expression(test, context))
              execute_children(child.children, context)
              matched = true
            end
          else
            execute_children(child.children, context)
            matched = true
          end
        end
      end

      # Copies a non-XSLT element of the stylesheet to the result tree,
      # expanding attribute value templates, and processes its children
      # with the new element as the output parent.
      def execute_literal_element(source, context)
        element = REXML::Element.new(source.expanded_name)
        parent_namespaces = context.output.respond_to?(:namespaces) ?
                            context.output.namespaces : {}
        source.namespaces.each do |prefix, uri|
          next if uri == XSL_NAMESPACE || prefix == "xml"
          next if parent_namespaces[prefix] == uri
          if prefix.empty?
            element.add_namespace(uri)
          else
            element.add_namespace(prefix, uri)
          end
        end
        source.attributes.each_attribute do |attribute|
          next if attribute.namespace_declaration?
          element.add_attribute(attribute_expanded_name(attribute),
                                expand_attribute_value(attribute.value, context))
        end
        context.output << element
        execute_children(source.children, context.derive(output: element))
      end

      def attribute_expanded_name(attribute)
        if attribute.prefix.empty?
          attribute.name
        else
          "#{attribute.prefix}:#{attribute.name}"
        end
      end

      # Expands {expression} attribute value templates; {{ and }} are
      # literal braces.
      def expand_attribute_value(value, context)
        return value unless value.include?("{") || value.include?("}")
        result = +""
        index = 0
        while index < value.length
          char = value[index]
          if char == "{"
            if value[index + 1] == "{"
              result << "{"
              index += 2
            else
              finish = attribute_value_template_end(value, index)
              expression = value[(index + 1)...finish]
              result << xpath_string(evaluate_expression(expression, context))
              index = finish + 1
            end
          elsif char == "}"
            if value[index + 1] == "}"
              result << "}"
              index += 2
            else
              raise Error, "unmatched '}' in attribute value template: #{value.inspect}"
            end
          else
            result << char
            index += 1
          end
        end
        result
      end

      def attribute_value_template_end(value, start)
        quote = nil
        index = start + 1
        while index < value.length
          char = value[index]
          if quote
            quote = nil if char == quote
          elsif char == "'" || char == '"'
            quote = char
          elsif char == "}"
            return index
          end
          index += 1
        end
        raise Error, "unterminated '{' in attribute value template: #{value.inspect}"
      end

      def evaluate_with_params(instruction, context)
        params = {}
        instruction.children.each do |child|
          next if child.node_type == :text && child.value.strip.empty?
          unless Template.xsl_element_named?(child, "with-param")
            raise Error, "only xsl:with-param is allowed inside xsl:#{instruction.name}"
          end
          param = Template.parse_param(child)
          params[param.name] =
            if param.select
              evaluate_expression(param.select, context)
            else
              evaluate_result_fragment(param.content, context)
            end
        end
        params
      end

      def evaluate_param_default(param, context)
        if param.select
          evaluate_expression(param.select, context)
        else
          evaluate_result_fragment(param.content, context)
        end
      end

      # Runs the content of an xsl:param or xsl:with-param into a
      # temporary fragment and returns its string value.
      def evaluate_result_fragment(element, context)
        fragment = REXML::Document.new
        execute_children(element.children,
                         context.derive(output: fragment, params: {}))
        string_value(fragment)
      end

      def required_attribute(instruction, name)
        value = instruction.attributes[name]
        if value.nil? || value.empty?
          raise Error, "xsl:#{instruction.name} requires a #{name} attribute"
        end
        value
      end

      # Evaluates an XPath expression against the current context.  The
      # context position and size are injected so that position() and
      # last() reflect the node list being processed.
      def evaluate_expression(expression, context)
        if DOCUMENT_FUNCTION.match?(expression)
          raise Error, "document() is not supported: #{expression.inspect}"
        end
        @xpath.variables = context.variables
        @xpath.evaluate(expression, context.node,
                        node: context.node,
                        position: context.position,
                        size: context.size)
      rescue Error
        raise
      rescue StandardError => exception
        raise Error, "cannot evaluate expression #{expression.inspect}: #{exception.message}"
      end

      # Converts an XPath value to a string, following the XSLT rules:
      # the string value of the first node of a node-set, XPath number
      # formatting, and "true"/"false" for booleans.
      def xpath_string(value)
        case value
        when Array
          value.empty? ? "" : xpath_string(value.first)
        when Numeric
          format_number(value)
        when true, false
          value.to_s
        when nil
          ""
        else
          value.respond_to?(:node_type) ? node_string_value(value) : value.to_s
        end
      end

      def node_string_value(node)
        case node.node_type
        when :attribute, :text
          node.value
        when :element, :document
          string_value(node)
        when :comment
          node.string
        when :processing_instruction
          node.content
        else
          node.to_s
        end
      end

      # The concatenation of the descendant text nodes of +node+.
      def string_value(node)
        result = +""
        node.children.each do |child|
          case child.node_type
          when :text
            result << child.value
          when :element
            result << string_value(child)
          end
        end
        result
      end

      def format_number(value)
        if value.is_a?(Float)
          return "NaN" if value.nan?
          return "Infinity" if value.infinite? == 1
          return "-Infinity" if value.infinite? == -1
          return value.to_i.to_s if value == value.truncate
        end
        value.to_s
      end

      def xpath_boolean(value)
        case value
        when Array
          !value.empty?
        when Numeric
          value != 0 && !(value.is_a?(Float) && value.nan?)
        when String
          !value.empty?
        when nil, false
          false
        else
          true
        end
      end
    end
  end
end
