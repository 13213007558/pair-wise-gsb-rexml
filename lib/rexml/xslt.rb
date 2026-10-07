# frozen_string_literal: true

require_relative "document"
require_relative "xpath"
require_relative "parsers/xpathparser"

module REXML
  module XSLT
    XSL_NAMESPACE = "http://www.w3.org/1999/XSL/Transform"
    DEFAULT_MODE = "#default"
    private_constant :DEFAULT_MODE

    class Error < StandardError
    end

    class CompilationError < Error
    end

    class ExecutionError < Error
    end

    require_relative "xslt/pattern"

    TemplateRule = Struct.new(
      :element,
      :uri,
      :import_precedence,
      :declaration_order,
      :mode,
      :pattern,
      :namespaces,
      :priority,
      :priority_source,
      :parameters,
      keyword_init: true
    )

    NamedTemplate = Struct.new(
      :element,
      :uri,
      :name,
      :import_precedence,
      :declaration_order,
      :namespaces,
      :parameters,
      keyword_init: true
    )

    ParameterDefinition = Struct.new(
      :element,
      :uri,
      :name,
      :select,
      :import_precedence,
      :declaration_order,
      :global,
      keyword_init: true
    )

    class Result < Struct.new(:document, :selections)
      def to_s
        document.to_s
      end
    end

    class Processor
      def initialize(entry_uri, resources, parameters = {})
        @entry_uri = entry_uri.to_s
        @resources = resources || {}
        @external_parameters = stringify_keys(parameters || {})
        @rules = []
        @named_templates = {}
        @global_parameters = []
        @namespaces = {}
        @declaration_order = 0
        compile
      end

      def transform(source)
        document = source.is_a?(Document) ? source : Document.new(source.to_s)
        runtime = Runtime.new(self, document)
        runtime.transform
      end

      def self.transform(entry_uri, resources, source, parameters = {})
        new(entry_uri, resources, parameters).transform(source)
      end
      def internal_rules
        @rules
      end

      def internal_named_templates
        @named_templates
      end

      def internal_global_parameters
        @global_parameters
      end

      def internal_namespaces
        @namespaces
      end

      def internal_external_parameters
        @external_parameters
      end

      def global_lookup(name)
        global_parameter(name)
      end

      def resolve_name(value, namespaces)
        parse_qname(value, false, namespaces)
      end

      def pattern_nodes(pattern, document, namespaces = @namespaces)
        matched = {}
        pattern.xpaths.each do |xpath|
          validate_xpath(xpath)
          REXML::XPath.match(document, xpath, namespaces).each do |node|
            matched[node.object_id] = node
          end
        end
        matched
      end

      def validate_xpath(expression)
        REXML::Parsers::XPathParser.new.parse(expression)
      rescue RuntimeError, REXML::ParseException => error
        raise CompilationError, "Unsupported XPath expression #{expression.inspect}: #{error.message}"
      end

      def display_qname(name)
        uri, local_name = name[1..-1].split("}", 2)
        uri.to_s.empty? ? local_name : name
      end

      private

      def compile
        load_module(@entry_uri, [])
        @rules.sort_by! do |rule|
          [-rule.import_precedence, -rule.priority, -rule.declaration_order]
        end
        resolve_named_template_conflicts
      end

      def load_module(uri, importing)
        source = fetch_resource(uri)
        document = source.is_a?(Document) ? source : Document.new(source.to_s)
        root = document.root
        validate_stylesheet_root(root, uri)
        if importing.include?(uri)
          cycle = (importing + [uri]).join(" -> ")
          raise CompilationError, "Cyclic stylesheet import: #{cycle}"
        end
        @namespaces = root.namespaces if importing.empty?

        root.children.each do |child|
          next unless xsl_element?(child)
          next unless child.name == "import"
          href = child.attribute("href")&.value.to_s
          raise CompilationError, "xsl:import requires href in #{uri}" if href.empty?
          imported_uri = resolve_uri(uri, href)
          load_module(imported_uri, importing + [uri])
        end
        precedence = next_precedence
        compile_top_level(root, uri, precedence, root.namespaces)
        precedence
      end

      def fetch_resource(uri)
        unless @resources.key?(uri)
          raise CompilationError, "Missing offline stylesheet resource: #{uri}"
        end
        @resources[uri]
      end

      def resolve_uri(base_uri, href)
        return href if href.start_with?("/") || href =~ /\A[a-z][a-z0-9+.-]*:/i
        directory = base_uri.include?("/") ? base_uri.rpartition("/").first : ""
        path_parts = []
        "#{directory}/#{href}".split("/").each do |part|
          next if part.empty? || part == "."
          if part == ".."
            path_parts.pop
          else
            path_parts << part
          end
        end
        path_parts.join("/")
      end

      def validate_stylesheet_root(root, uri)
        unless root && root.namespace == XSL_NAMESPACE &&
               (root.name == "stylesheet" || root.name == "transform")
          raise CompilationError, "#{uri} is not an XSLT stylesheet"
        end
        unless root.attribute("version")&.value == "1.0"
          raise CompilationError, "Only XSLT 1.0 stylesheets are supported: #{uri}"
        end
      end

      def compile_top_level(root, uri, import_precedence, namespaces)
        children = root.children
        non_import_seen = false
        children.each do |child|
          if whitespace_text?(child) || child.is_a?(Comment) || child.is_a?(Instruction)
            next
          end
          unless xsl_element?(child)
            raise CompilationError, unsupported_message(child, uri)
          end

          case child.name
          when "import"
            if non_import_seen
              raise CompilationError, "xsl:import must precede other top-level elements in #{uri}"
            end
          when "template"
            compile_template(child, uri, import_precedence, namespaces)
            non_import_seen = true
          when "param"
            compile_global_parameter(child, uri, import_precedence)
            non_import_seen = true
          else
            raise CompilationError, unsupported_message(child, uri)
          end
        end
      end

      def compile_template(element, uri, import_precedence, namespaces)
        allowed = %w[match name mode priority]
        validate_attributes(element, allowed, uri)
        match = element.attribute("match")&.value
        name = element.attribute("name")&.value
        raise CompilationError, "xsl:template requires match or name in #{uri}" if match.nil? && name.nil?
        parameters = compile_parameters(element.children, uri, namespaces)
        validate_sequence(element.children, uri, namespaces)

        if match
          mode = parse_qname(element.attribute("mode")&.value, true, namespaces)
          pattern = compile_pattern(match, uri, namespaces)
          priority_attribute = element.attribute("priority")&.value
          priority = priority_attribute ? parse_priority(priority_attribute, uri) : pattern.default_priority
          @rules << TemplateRule.new(
            element: element,
            uri: uri,
            import_precedence: import_precedence,
            declaration_order: next_declaration_order,
            mode: mode,
            pattern: pattern,
            namespaces: namespaces,
            priority: priority,
            priority_source: priority_attribute ? "explicit priority=#{priority_attribute}" : "default priority",
            parameters: parameters
          )
        elsif element.attribute("mode") || element.attribute("priority")
          raise CompilationError, "mode and priority require match on xsl:template in #{uri}"
        end

        if name
          expanded_name = parse_qname(name, false, namespaces)
          @named_templates[expanded_name] ||= []
          @named_templates[expanded_name] << NamedTemplate.new(
            element: element,
            uri: uri,
            name: expanded_name,
            import_precedence: import_precedence,
            declaration_order: next_declaration_order,
            namespaces: namespaces,
            parameters: parameters
          )
        end
      end

      def compile_global_parameter(element, uri, import_precedence)
        validate_attributes(element, %w[name select], uri)
        name = required_qname(element, "name", uri)
        validate_parameter_body(element, uri, @namespaces)
        @global_parameters << ParameterDefinition.new(
          element: element,
          uri: uri,
          name: name,
          select: element.attribute("select")&.value,
          import_precedence: import_precedence,
          declaration_order: next_declaration_order,
          global: true
        )
      end

      def compile_parameters(children, uri, namespaces)
        parameters = []
        children.each do |child|
          next if whitespace_text?(child) || child.is_a?(Comment) || child.is_a?(Instruction)
          if xsl_element?(child)
            if child.name == "param"
              validate_attributes(child, %w[name select], uri)
              validate_parameter_body(child, uri, namespaces)
              parameters << ParameterDefinition.new(
                element: child,
                uri: uri,
                name: required_qname(child, "name", uri, namespaces),
                select: child.attribute("select")&.value,
                import_precedence: nil,
                declaration_order: next_declaration_order,
                global: false
              )
            elsif parameters.any?
              return parameters
            else
              return parameters
            end
          elsif parameters.any?
            return parameters
          else
            return parameters
          end
        end
        parameters
      end

      def validate_sequence(children, uri, namespaces = @namespaces)
        children.each do |child|
          next if whitespace_text?(child) || child.is_a?(Comment) || child.is_a?(Instruction) ||
                  child.is_a?(CData)
          if xsl_element?(child)
            validate_instruction(child, uri, namespaces) unless child.name == "param"
          end
          if child.is_a?(Element) && !xsl_element?(child)
            reject_xsl_attributes(child, uri)
            validate_sequence(child.children, uri, namespaces)
          end
        end
      end

      def validate_instruction(element, uri, namespaces = @namespaces)
        case element.name
        when "param"
          raise CompilationError, "xsl:param is only allowed at the start of xsl:template in #{uri}"
        when "apply-templates"
          validate_attributes(element, %w[select mode], uri)
          validate_select_attribute(element, uri)
          validate_with_parameters(element, uri, namespaces)
        when "call-template"
          validate_attributes(element, %w[name], uri)
          validate_with_parameters(element, uri, namespaces)
          raise CompilationError, "xsl:call-template requires name in #{uri}" unless element.attribute("name")
        when "value-of"
          validate_attributes(element, %w[select], uri)
          validate_select_attribute(element, uri)
          raise CompilationError, "xsl:value-of requires select in #{uri}" unless element.attribute("select")
          reject_children(element, uri)
        when "with-param"
          raise CompilationError, "xsl:with-param must be a child of apply-templates or call-template in #{uri}"
        else
          raise CompilationError, unsupported_message(element, uri)
        end
      end

      def validate_with_parameters(element, uri, namespaces)
        element.children.each do |child|
          next if whitespace_text?(child) || child.is_a?(Comment) || child.is_a?(Instruction)
          unless xsl_element?(child) && child.name == "with-param"
            raise CompilationError, unsupported_message(child, uri)
          end
          validate_attributes(child, %w[name select], uri)
          validate_select_attribute(child, uri)
          parse_qname(child.attribute("name").value, false, namespaces)
          raise CompilationError, "xsl:with-param requires name and select in #{uri}" unless
            child.attribute("name") && child.attribute("select")
          reject_children(child, uri)
        end
      end

      def validate_parameter_body(element, uri, namespaces = @namespaces)
        if element.attribute("select")
          validate_select_attribute(element, uri)
          reject_children(element, uri)
          return
        end
        element.children.each do |child|
          next if whitespace_text?(child) || child.is_a?(Comment) || child.is_a?(Instruction) ||
                  child.is_a?(CData)
          if xsl_element?(child)
            validate_instruction(child, uri, namespaces)
          elsif child.is_a?(Element)
            reject_xsl_attributes(child, uri)
            validate_sequence(child.children, uri, namespaces)
          end
        end
      end

      def validate_attributes(element, allowed, uri)
        element.attributes.each_attribute do |attribute|
          name = attribute.expanded_name
          next if name.start_with?("xmlns")
          unless allowed.include?(name)
            raise CompilationError, "Unsupported attribute #{name} on #{element_name(element)} in #{uri}"
          end
        end
      end

      def validate_select_attribute(element, uri)
        select = element.attribute("select")
        return unless select
        validate_xpath(select.value)
      rescue CompilationError
        raise CompilationError,
              "Unsupported select expression #{select.value.inspect} on #{element_name(element)} in #{uri}"
      end

      def reject_children(element, uri)
        element.children.each do |child|
          next if whitespace_text?(child) || child.is_a?(Comment) || child.is_a?(Instruction)
          raise CompilationError, "#{element_name(element)} cannot contain #{element_name(child)} in #{uri}"
        end
      end

      def reject_xsl_attributes(element, uri)
        element.attributes.each_attribute do |attribute|
          if attribute.namespace == XSL_NAMESPACE
            raise CompilationError, "Unsupported XSLT attribute #{attribute.expanded_name} on #{element_name(element)} in #{uri}"
          elsif attribute.value.include?("{") || attribute.value.include?("}")
            raise CompilationError, "Attribute value templates are not supported on #{element_name(element)} in #{uri}"
          end
        end
      end

      def compile_pattern(match, uri, namespaces = @namespaces)
        pattern = Pattern.parse(match, namespaces)
        pattern.xpaths.each { |xpath| validate_xpath(xpath) }
        pattern
      rescue PatternError => error
        raise CompilationError, "Unsupported match pattern #{match.inspect} in #{uri}: #{error.message}"
      end

      def parse_priority(value, uri)
        Float(value)
      rescue ArgumentError
        raise CompilationError, "Invalid priority #{value.inspect} in #{uri}"
      end

      def parse_qname(value, allow_nil, namespaces = @namespaces)
        return DEFAULT_MODE if value.nil? && allow_nil
        raise CompilationError, "Missing QName" if value.nil?
        prefix, local_name = split_qname(value)
        namespace_uri = prefix ? namespaces[prefix] : ""
        raise CompilationError, "Unbound namespace prefix in QName: #{value}" if prefix && namespace_uri.nil?
        "{#{namespace_uri}}#{local_name}"
      end

      def required_qname(element, attribute_name, uri, namespaces = @namespaces)
        value = element.attribute(attribute_name)&.value
        raise CompilationError, "#{element_name(element)} requires #{attribute_name} in #{uri}" if value.nil? || value.empty?
        parse_qname(value, false, namespaces)
      end

      def split_qname(value)
        match = value.match(/\A(?:([\w.-]+):)?([\w.-]+)\z/)
        raise CompilationError, "Invalid QName: #{value}" unless match
        [match[1], match[2]]
      end

      def resolve_named_template_conflicts
        @named_templates.each do |name, candidates|
          candidates.sort_by! { |template| [-template.import_precedence, -template.declaration_order] }
          winner = candidates.first
          ties = candidates.select do |candidate|
            candidate.import_precedence == winner.import_precedence
          end
          if ties.size > 1
            raise CompilationError, "Multiple named templates #{name} have the same import precedence"
          end
        end
      end

      def next_precedence
        @precedence ||= 0
        @precedence += 1
      end

      def next_declaration_order
        @declaration_order += 1
      end

      def xsl_element?(node)
        node.is_a?(Element) && node.namespace == XSL_NAMESPACE
      end

      def whitespace_text?(node)
        node.is_a?(Text) && !node.is_a?(CData) && node.value.strip.empty?
      end

      def unsupported_message(element, uri)
        if xsl_element?(element)
          "Unsupported XSLT instruction xsl:#{element.name} in #{uri}"
        else
          "Unsupported top-level element #{element_name(element)} in #{uri}"
        end
      end

      def element_name(element)
        xsl_element?(element) ? "xsl:#{element.name}" : element.expanded_name
      end

      def stringify_keys(hash)
        hash.each_with_object({}) do |(key, value), result|
          result[key.to_s] = value
        end
      end

      def global_parameter(name)
        external_key = @external_parameters.key?(name) ? name : display_qname(name)
        if @external_parameters.key?(name)
          return [:external, @external_parameters[name]]
        elsif @external_parameters.key?(external_key)
          return [:external, @external_parameters[external_key]]
        end
        candidates = @global_parameters.select { |parameter| parameter.name == name }
        candidate = candidates.max_by { |parameter| [parameter.import_precedence, parameter.declaration_order] }
        candidate ? [:definition, candidate] : nil
      end
    end

    class Runtime
      Frame = Struct.new(:node, :mode, :variables, :globals, keyword_init: true)

      def initialize(processor, document)
        @processor = processor
        @document = document
        @selections = []
        @pattern_matches = {}
        @global_stack = {}
        @functions = FunctionsClass.new
      end

      def transform
        output = Document.new
        frame = Frame.new(node: @document, mode: DEFAULT_MODE, variables: {}, globals: {})
        apply_node(@document, DEFAULT_MODE, frame.variables, output, "initial", frame.globals)
        Result.new(output, @selections)
      end

      private

      def rules
        @processor.internal_rules
      end

      def apply_node(node, mode, variables, output, invocation, globals = {})
        rule, candidates = find_rule(node, mode, invocation)
        @selections << selection_record(node, mode, invocation, rule, candidates)
        if rule.is_a?(TemplateRule)
          local_variables = passed_variables(rule, variables, node, globals)
          instantiate(rule, node, mode, local_variables, output, globals)
        else
          apply_builtin(node, mode, variables, output, globals)
        end
      end

      def find_rule(node, mode, invocation)
        candidates = matching_rules(node, mode)
        if candidates.any?
          [candidates.first, candidates]
        else
          [builtin_kind(node), builtin_candidates(mode, invocation)]
        end
      end

      def matching_rules(node, mode)
        rules.select do |rule|
          rule.mode == mode && pattern_matches?(rule, node)
        end
      end

      def pattern_matches?(rule, node)
        @pattern_matches[rule.object_id] ||= begin
          nodes = {}
          @processor.pattern_nodes(rule.pattern, @document, rule.namespaces).each do |id, matched_node|
            nodes[id] = matched_node
          end
          nodes
        end
        if node.node_type == :document
          rule.pattern.matches_document?
        else
          @pattern_matches[rule.object_id].key?(node.object_id)
        end
      end

      def builtin_kind(node)
        case node.node_type
        when :document, :element
          :builtin_children
        when :text, :attribute
          :builtin_text
        else
          :builtin_noop
        end
      end

      def builtin_candidates(mode, invocation)
        [{
          builtin: true,
          kind: "built-in template",
          mode: mode,
          reason: "no user template matched; built-in rule used for #{invocation}"
        }]
      end

      def selection_record(node, mode, invocation, rule, candidates)
        if rule == :builtin_text || rule == :builtin_children || rule == :builtin_noop
          {
            invocation: invocation,
            node: node_path(node),
            node_type: node.node_type,
            mode: mode,
            chosen: "built-in template (#{rule})",
            import_precedence: -1,
            priority: nil,
            basis: candidates.first[:reason],
            considered: candidates
          }
        else
          {
            invocation: invocation,
            node: node_path(node),
            node_type: node.node_type,
            mode: mode,
            chosen: template_label(rule),
            import_precedence: rule.import_precedence,
            priority: rule.priority,
            priority_source: rule.priority_source,
            basis: rule_basis(rule, candidates),
            considered: candidates.collect { |candidate| rule_summary(candidate) }
          }
        end
      end

      def rule_basis(winner, candidates)
        lower = candidates[1..-1] || []
        import = "import precedence #{winner.import_precedence}"
        priority = "#{winner.priority_source} (#{format_priority(winner.priority)})"
        if lower.empty?
          "only matching user template; #{import}; #{priority}"
        elsif lower.first.import_precedence < winner.import_precedence
          "highest import precedence; #{import}; #{priority}"
        elsif lower.first.priority < winner.priority
          "higher priority; #{import}; #{priority}"
        else
          "same import precedence and priority; declaration order tie resolved to last template; #{priority}"
        end
      end

      def rule_summary(rule)
        {
          template: template_label(rule),
          match: rule.pattern.source,
          mode: rule.mode,
          import_precedence: rule.import_precedence,
          priority: rule.priority,
          priority_source: rule.priority_source,
          declaration_order: rule.declaration_order
        }
      end

      def template_label(rule)
        "#{rule.uri}#template[#{rule.declaration_order}] match=#{rule.pattern.source}"
      end

      def apply_builtin(node, mode, variables, output, globals)
        case builtin_kind(node)
        when :builtin_children
          default_children(node).each do |child|
            apply_node(child, mode, variables, output, "built-in apply-templates", globals)
          end
        when :builtin_text
          add_text(output, node_string(node))
        end
      end

      def instantiate(rule, node, mode, variables, output, globals)
        execute_sequence(
          rule.element.children,
          Frame.new(node: node, mode: mode, variables: variables, globals: globals),
          output
        )
      end

      def execute_sequence(children, frame, output)
        children.each do |child|
          next if skip_stylesheet_node?(child)
          if xsl?(child)
            execute_instruction(child, frame, output)
          elsif child.is_a?(Element)
            emit_literal_element(child, frame, output)
          elsif child.is_a?(Text)
            add_text(output, child.value)
          elsif child.is_a?(Comment)
            output << Comment.new(child)
          elsif child.is_a?(Instruction)
            output << Instruction.new(child)
          end
        end
      end

      def execute_instruction(element, frame, output)
        case element.name
        when "apply-templates"
          execute_apply_templates(element, frame, output)
        when "call-template"
          execute_call_template(element, frame, output)
        when "value-of"
          value = evaluate(element.attribute("select").value, frame.node, frame.variables, frame.globals)
          add_text(output, xpath_string(value))
        when "param"
          nil
        else
          raise ExecutionError, "Unsupported instruction reached runtime: xsl:#{element.name}"
        end
      end

      def execute_apply_templates(element, frame, output)
        mode = element.attribute("mode") ? @processor.resolve_name(element.attribute("mode").value, element.namespaces) : DEFAULT_MODE
        nodes = selected_nodes(element.attribute("select")&.value, frame)
        parameters = with_parameters(element, frame)
        invocation = "apply-templates#{element.attribute('mode') ? " mode=#{element.attribute('mode').value}" : ''}"
        nodes.each do |node|
          apply_node(node, mode, parameters, output, invocation, frame.globals)
        end
      end

      def execute_call_template(element, frame, output)
        name = @processor.resolve_name(element.attribute("name").value, element.namespaces)
        template = @processor.internal_named_templates[name]&.first
        unless template
          raise ExecutionError, "Named template not found: #{element.attribute('name').value}"
        end
        parameters = with_parameters(element, frame)
        variables = passed_named_variables(template, parameters, frame.node, frame.globals)
        @selections << {
          invocation: "call-template name=#{element.attribute('name').value}",
          node: node_path(frame.node),
          mode: frame.mode,
          chosen: "#{template.uri}#named-template(#{element.attribute('name').value})",
          import_precedence: template.import_precedence,
          basis: "named by xsl:call-template; mode #{frame.mode} is not changed",
          considered: [{
            template: "#{template.uri}#named-template(#{element.attribute('name').value})",
            name: element.attribute('name').value,
            import_precedence: template.import_precedence,
            declaration_order: template.declaration_order
          }]
        }
        execute_sequence(template.element.children,
                         Frame.new(node: frame.node, mode: frame.mode, variables: variables, globals: frame.globals),
                         output)
      end

      def selected_nodes(expression, frame)
        return default_nodes(frame.node) unless expression
        value = evaluate(expression, frame.node, frame.variables, frame.globals)
        unless value.is_a?(Array) && value.all? { |item| item.is_a?(Node) }
          raise ExecutionError, "select must return a node-set: #{expression}"
        end
        XPathParser.sort(value)
      end

      def default_nodes(node)
        default_children(node)
      end

      def default_children(node)
        node.children.select do |child|
          child.is_a?(Element) || child.is_a?(Text) ||
            child.is_a?(Comment) || child.is_a?(Instruction)
        end
      end

      def emit_literal_element(source, frame, output)
        element = Element.new(source.expanded_name)
        source.attributes.each_attribute do |attribute|
          element.add_attribute(attribute.expanded_name, attribute.value)
        end
        output << element
        execute_sequence(source.children, frame, element)
      end

      def with_parameters(element, frame)
        parameters = {}
        element.children.each do |child|
          next unless xsl?(child) && child.name == "with-param"
          name = @processor.resolve_name(child.attribute("name").value, child.namespaces)
          parameters[name] = evaluate(child.attribute("select").value, frame.node, frame.variables, frame.globals)
        end
        parameters
      end

      def passed_variables(rule, caller_variables, node, globals)
        variables = {}
        rule.parameters.each do |parameter|
          if caller_variables.key?(parameter.name)
            variables[parameter.name] = caller_variables[parameter.name]
          else
            variables[parameter.name] = parameter_value(parameter, node, variables, globals)
          end
        end
        variables
      end

      def passed_named_variables(template, caller_variables, node, globals)
        variables = {}
        template.parameters.each do |parameter|
          if caller_variables.key?(parameter.name)
            variables[parameter.name] = caller_variables[parameter.name]
          else
            variables[parameter.name] = parameter_value(parameter, node, variables, globals)
          end
        end
        variables
      end

      def parameter_value(parameter, node, local_variables, globals)
        if parameter.select
          evaluate(parameter.select, node, local_variables, globals)
        else
          capture_sequence(parameter.element.children, node, local_variables, globals)
        end
      end

      def global_value(name, node, globals)
        return globals[name] if globals.key?(name)
        lookup = @processor.global_lookup(name)
        unless lookup
          globals[name] = ""
          return globals[name]
        end
        kind, value = lookup
        if kind == :external
          globals[name] = value
        else
          raise ExecutionError, "Cyclic global parameter: #{name}" if @global_stack[name]
          @global_stack[name] = true
          globals[name] =
            if value.select
              evaluate(value.select, node, {}, globals)
            else
              capture_sequence(value.element.children, node, {}, globals)
            end
          @global_stack.delete(name)
          globals[name]
        end
      end

      def capture_sequence(children, node, variables, globals)
        document = Document.new
        execute_sequence(
          children,
          Frame.new(node: node, mode: DEFAULT_MODE, variables: variables, globals: globals),
          document
        )
        node_string(document)
      end

      def evaluate(expression, node, variables, globals = {})
        value = REXML::XPath.match(
          node,
          expression,
          @processor.internal_namespaces,
          resolved_variables(variables, node, globals)
        )
        if value.is_a?(Array) && value.size == 1 && !value.first.is_a?(Node)
          value.first
        else
          value
        end
      rescue REXML::ParseException, RuntimeError => error
        raise ExecutionError, "Failed to evaluate XPath #{expression.inspect}: #{error.message}"
      end

      def resolved_variables(variables, node, globals)
        result = {}
        variables.each do |name, value|
          result[name] = value
          result[@processor.display_qname(name)] = value
        end
        @processor.internal_external_parameters.each do |key, value|
          result[key] = value unless result.key?(key)
        end
        @processor.internal_global_parameters.each do |parameter|
          display_name = @processor.display_qname(parameter.name)
          next if result.key?(parameter.name) || result.key?(display_name)
          value = global_value(parameter.name, node, globals)
          result[parameter.name] = value
          result[display_name] = value
        end
        result
      end

      def xpath_string(value)
        value = value.first if value.is_a?(Array)
        return "" if value.nil?
        return node_string(value) if value.is_a?(Node)
        @functions.string(value)
      end

      def node_string(node)
        case node
        when Document
          node.root ? node_string(node.root) : ""
        when Attribute
          node.value
        when Text
          node.value
        when Instruction
          node.content.to_s
        when Element
          node.children.collect { |child| child.is_a?(Text) || child.is_a?(Element) ? node_string(child) : "" }.join
        else
          node.to_s
        end
      end

      def add_text(output, value)
        return if value.nil? || value.empty?
        output.add_text(value)
      end

      def node_path(node)
        case node.node_type
        when :document
          "/"
        when :attribute
          "#{node_path(node.element)}/@#{node.expanded_name}"
        when :text
          "#{node_path(node.parent)}/text()"
        when :comment
          "#{node_path(node.parent)}/comment()"
        when :processing_instruction
          "#{node_path(node.parent)}/processing-instruction(#{node.target})"
        else
          element_path(node)
        end
      end

      def element_path(node)
        parts = []
        current = node
        while current && current.node_type != :document
          parts.unshift(current.expanded_name)
          current = current.parent
        end
        "/" + parts.join("/")
      end

      def skip_stylesheet_node?(node)
        node.is_a?(Text) && !node.is_a?(CData) && node.value.strip.empty?
      end

      def xsl?(node)
        node.is_a?(Element) && node.namespace == XSL_NAMESPACE
      end

      def format_priority(value)
        value.nil? ? "default" : value.to_s
      end
    end
  end
end
