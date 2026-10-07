# frozen_string_literal: true

require "rexml/document"
require_relative "errors"
require_relative "pattern"

module REXML
  module XSLT
    # Expands a QName using a namespace map.  Unprefixed names are in no
    # namespace (modes, template names and pattern names never use the
    # default namespace).  Returns a "{uri}local" string, or the plain
    # local name when there is no prefix.
    def self.expand_qname(qname, namespaces, error_class: StylesheetError)
      if qname.include?(":")
        prefix, local = qname.split(":", 2)
        uri = namespaces[prefix] or
          raise error_class, "unknown namespace prefix #{prefix.inspect} in #{qname.inspect}"
        "{#{uri}}#{local}"
      else
        qname
      end
    end

    # A compiled xsl:template.
    class Template
      # A template-level xsl:param: name plus its default select
      # expression (nil means the default is the empty string).
      Param = Struct.new(:name, :select)

      attr_reader :element, :pattern, :name, :mode, :mode_lexical,
                  :explicit_priority, :precedence, :sequence, :module_uri,
                  :parameters

      def initialize(element:, pattern:, name:, mode:, mode_lexical:,
                     explicit_priority:, precedence:, sequence:,
                     module_uri:, parameters:)
        @element = element
        @pattern = pattern
        @name = name
        @mode = mode
        @mode_lexical = mode_lexical
        @explicit_priority = explicit_priority
        @precedence = precedence
        @sequence = sequence
        @module_uri = module_uri
        @parameters = parameters
      end

      def match_pattern?
        !@pattern.nil?
      end

      # The priority used when this rule matches through +alternative+.
      def priority_for(alternative)
        @explicit_priority || alternative.default_priority
      end

      def description
        parts = []
        parts << "match=#{pattern.source.inspect}" if pattern
        parts << "name=#{name.inspect}" if name
        parts << "mode=#{mode_lexical.inspect}" if mode_lexical
        "xsl:template[#{parts.join(' ')}] (##{sequence} in #{module_uri})"
      end
    end

    # A compiled stylesheet: a set of template rules with import
    # precedence, named templates and global parameters, ready to be
    # executed by Processor.
    #
    # Stylesheets are compiled from strings.  xsl:import is resolved
    # exclusively against an explicit offline resource table (a Hash of
    # URI => stylesheet source); URIs that are not present in the table
    # raise UnknownResourceError.  Nothing is read from the filesystem or
    # the network.
    #
    # Compilation performs full static validation: any XSLT instruction
    # outside the supported subset raises UnsupportedInstructionError
    # before any source node is processed.
    class Stylesheet
      # Instructions supported inside template bodies.
      TEMPLATE_INSTRUCTIONS = %w[
        apply-templates call-template value-of param with-param text
      ].freeze

      # Top-level definitions supported in xsl:stylesheet.
      TOP_LEVEL_DEFINITIONS = %w[import template param].freeze

      attr_reader :rules, :named_templates, :global_params

      # Compiles +source+ (a String or anything REXML::Document accepts).
      #
      # +resources+ maps URIs to stylesheet sources and is the only way
      # xsl:import hrefs are resolved.  +base_uri+ is a label used in
      # error messages and traces.
      def self.compile(source, resources: {}, base_uri: "(stylesheet)")
        sheet = new
        sheet.send(:compile_module, source, resources, base_uri, [base_uri])
        sheet
      end

      def initialize
        @rules = []
        @named_templates = {}
        @global_params = [] # [[name, select_or_nil], ...]
        @precedence_counter = 0
        @sequence_counter = 0
      end

      private

      def compile_module(source, resources, uri, import_stack)
        document =
          begin
            source.is_a?(REXML::Document) ? source : REXML::Document.new(source)
          rescue REXML::ParseException => error
            raise StylesheetError, "cannot parse stylesheet #{uri}: #{error.message}"
          end
        root = document.root
        unless root && root.namespace.to_s == NAMESPACE &&
               %w[stylesheet transform].include?(root.name)
          raise StylesheetError,
                "stylesheet #{uri} must have xsl:stylesheet or xsl:transform as its root element"
        end
        unless root.attributes["version"]
          raise StylesheetError, "stylesheet #{uri} is missing the required version attribute"
        end

        # xsl:import elements must precede every other top-level element
        # (XSLT 1.0 section 2.6.2).
        seen_non_import = false
        root.each_element do |child|
          next unless child.namespace.to_s == NAMESPACE
          if child.name == "import"
            if seen_non_import
              raise StylesheetError,
                    "xsl:import must precede all other top-level elements (#{uri})"
            end
            compile_import(child, resources, uri, import_stack)
          else
            seen_non_import = true
          end
        end

        # Import precedence: a module outranks every module it imports,
        # and a module imported later outranks one imported earlier.
        # Compiling imports first and numbering modules in completion
        # order yields exactly that.
        precedence = (@precedence_counter += 1)

        root.each_element do |child|
          next unless child.namespace.to_s == NAMESPACE
          next if child.name == "import"
          compile_top_level(child, precedence, uri)
        end
      end

      def compile_import(element, resources, uri, import_stack)
        href = element.attributes["href"]
        raise StylesheetError, "xsl:import requires an href attribute (#{uri})" if href.nil?
        if import_stack.include?(href)
          chain = (import_stack + [href]).join(" -> ")
          raise CircularImportError, "circular xsl:import detected: #{chain}"
        end
        imported = resources[href]
        if imported.nil?
          raise UnknownResourceError,
                "xsl:import href=#{href.inspect} (#{uri}) is not in the offline resource table; " \
                "stylesheets are never fetched from the filesystem or the network"
        end
        compile_module(imported, resources, href, import_stack + [href])
      end

      def compile_top_level(element, precedence, uri)
        name = element.name
        unless TOP_LEVEL_DEFINITIONS.include?(name)
          raise UnsupportedInstructionError,
                "xsl:#{name} is not supported at the top level (#{uri})"
        end
        case name
        when "template" then compile_template(element, precedence, uri)
        when "param" then compile_global_param(element, uri)
        end
      end

      def compile_global_param(element, uri)
        name = element.attributes["name"]
        raise StylesheetError, "xsl:param requires a name attribute (#{uri})" if name.nil?
        reject_param_content!(element, uri)
        @global_params << [name, element.attributes["select"]]
      end

      def compile_template(element, precedence, uri)
        match = element.attributes["match"]
        name = element.attributes["name"]
        if match.nil? && name.nil?
          raise StylesheetError,
                "xsl:template requires a match or name attribute (#{uri})"
        end
        pattern = match && Pattern.parse(match, element.namespaces)
        priority = parse_priority(element.attributes["priority"], uri)
        mode_lexical = element.attributes["mode"]
        mode = mode_lexical && XSLT.expand_qname(mode_lexical, element.namespaces)

        validate_template_content!(element, uri)
        parameters = extract_parameters(element, uri)
        sequence = (@sequence_counter += 1)

        template = Template.new(
          element: element,
          pattern: pattern,
          name: name && XSLT.expand_qname(name, element.namespaces),
          mode: mode,
          mode_lexical: mode_lexical,
          explicit_priority: priority,
          precedence: precedence,
          sequence: sequence,
          module_uri: uri,
          parameters: parameters,
        )
        @rules << template if pattern
        if name
          existing = @named_templates[template.name]
          if existing && existing.precedence == precedence
            raise StylesheetError,
                  "duplicate named template #{name.inspect} at the same import precedence (#{uri})"
          end
          # Modules are compiled in ascending import precedence order, so
          # a later assignment always belongs to a higher precedence and
          # correctly shadows the earlier definition.
          @named_templates[template.name] = template
        end
        template
      end

      def parse_priority(value, uri)
        return nil if value.nil?
        Float(value)
      rescue ArgumentError
        raise StylesheetError, "invalid priority #{value.inspect} (#{uri})"
      end

      def extract_parameters(template_element, uri)
        parameters = []
        template_element.each_element do |child|
          break unless child.namespace.to_s == NAMESPACE && child.name == "param"
          name = child.attributes["name"]
          raise StylesheetError, "xsl:param requires a name attribute (#{uri})" if name.nil?
          reject_param_content!(child, uri)
          parameters << Template::Param.new(name, child.attributes["select"])
        end
        parameters
      end

      def reject_param_content!(element, uri)
        return if element.attributes["select"]
        meaningful = element.children.any? do |child|
          child.is_a?(REXML::Element) ||
            (child.is_a?(REXML::Text) && !child.value.strip.empty?)
        end
        if meaningful
          raise UnsupportedInstructionError,
                "xsl:#{element.name} with a content-based default is not supported; " \
                "use a select attribute (#{uri})"
        end
      end

      # Statically validates every instruction in a template body so
      # that unsupported constructs fail before execution starts.
      def validate_template_content!(element, uri)
        seen_non_param = false
        element.each_element do |child|
          if child.namespace.to_s == NAMESPACE
            name = child.name
            unless TEMPLATE_INSTRUCTIONS.include?(name)
              raise UnsupportedInstructionError,
                    "xsl:#{name} is not supported (#{uri})"
            end
            if name == "param"
              if seen_non_param
                raise StylesheetError,
                      "xsl:param must precede all other template content (#{uri})"
              end
            else
              seen_non_param = true
            end
            validate_instruction!(child, uri)
          else
            seen_non_param = true
            # Literal result element: its content is template content too.
            validate_template_content!(child, uri)
          end
        end
      end

      def validate_instruction!(element, uri)
        case element.name
        when "apply-templates"
          validate_with_param_children!(element, uri)
        when "call-template"
          unless element.attributes["name"]
            raise StylesheetError, "xsl:call-template requires a name attribute (#{uri})"
          end
          validate_with_param_children!(element, uri)
        when "value-of"
          unless element.attributes["select"]
            raise StylesheetError, "xsl:value-of requires a select attribute (#{uri})"
          end
          if element.has_elements?
            raise StylesheetError, "xsl:value-of must be empty (#{uri})"
          end
        when "with-param"
          unless element.attributes["name"]
            raise StylesheetError, "xsl:with-param requires a name attribute (#{uri})"
          end
          reject_param_content!(element, uri)
        when "param"
          # Already handled by extract_parameters / compile_global_param.
        when "text"
          if element.has_elements?
            raise StylesheetError, "xsl:text must not contain elements (#{uri})"
          end
          if element.attributes.key?("disable-output-escaping")
            raise UnsupportedInstructionError,
                  "disable-output-escaping is not supported (#{uri})"
          end
        end
      end

      def validate_with_param_children!(element, uri)
        element.each_element do |child|
          unless child.namespace.to_s == NAMESPACE && child.name == "with-param"
            what = child.namespace.to_s == NAMESPACE ? "xsl:#{child.name}" : child.expanded_name
            raise UnsupportedInstructionError,
                  "#{what} inside xsl:#{element.name} is not supported; " \
                  "only xsl:with-param is allowed (#{uri})"
          end
          validate_instruction!(child, uri)
        end
      end
    end
  end
end
