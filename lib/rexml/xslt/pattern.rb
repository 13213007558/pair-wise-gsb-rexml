# frozen_string_literal: true

require_relative "errors"

module REXML
  module XSLT
    # A parsed XSLT 1.0 pattern (the +match+ attribute of xsl:template).
    #
    # Supported subset of the pattern grammar:
    #
    #   Pattern     ::= PathPattern ('|' PathPattern)*
    #   PathPattern ::= '/' | ('/' | '//')? Step (('/' | '//') Step)*
    #   Step        ::= ('@' | 'attribute::' | 'child::')? NodeTest
    #   NodeTest    ::= '*' | NCName ':*' | QName
    #                 | 'node()' | 'text()' | 'comment()'
    #                 | 'processing-instruction()' | 'processing-instruction(Literal)'
    #
    # Predicates, id()/key() and axes other than child/attribute are not
    # supported and raise PatternError at compile time.
    #
    # Default priorities follow XSLT 1.0 section 5.5:
    # * node type tests (node(), text(), comment(), processing-instruction())
    #   and wildcard name tests (*, ns:*, @*)  => -0.5
    # * specific QNames (@name included) and processing-instruction('lit')
    #                                                     =>  0
    # * anything else (multi-step paths, "/")              =>  0.5
    #   (union alternatives each get their own priority)
    class Pattern
      NCNAME = "[A-Za-z_][A-Za-z0-9_.\\-]*"

      # One step of a path pattern: an axis plus a node test.
      class Step
        attr_reader :axis, :test, :source

        # +test+ is one of:
        #   [:any]                 "*"
        #   [:ns_any, uri]         "ns:*"
        #   [:qname, uri, local]   "name" / "ns:name"
        #   [:type, :node|:text|:comment|:pi]
        #   [:pi_target, target]
        def initialize(axis, test, source)
          @axis = axis
          @test = test
          @source = source
        end

        def matches?(node)
          case test[0]
          when :any
            attribute_axis? ? node.is_a?(REXML::Attribute)
                            : Pattern.element_node?(node)
          when :ns_any
            uri = test[1]
            if attribute_axis?
              node.is_a?(REXML::Attribute) && node.namespace.to_s == uri
            else
              Pattern.element_node?(node) && node.namespace.to_s == uri
            end
          when :qname
            _, uri, local = test
            if attribute_axis?
              node.is_a?(REXML::Attribute) &&
                node.name == local && node.namespace.to_s == uri
            else
              Pattern.element_node?(node) &&
                node.name == local && node.namespace.to_s == uri
            end
          when :type
            case test[1]
            when :node
              !node.is_a?(REXML::Document) && !node.is_a?(REXML::Attribute)
            when :text
              node.is_a?(REXML::Text)
            when :comment
              node.is_a?(REXML::Comment)
            when :pi
              node.is_a?(REXML::Instruction)
            else
              false
            end
          when :pi_target
            node.is_a?(REXML::Instruction) && node.target == test[1]
          else
            false
          end
        end

        def attribute_axis?
          @axis == :attribute
        end

        # Default priority contribution of a pattern consisting of this
        # single step (XSLT 1.0 section 5.5).
        def default_priority
          case test[0]
          when :type then -0.5
          when :any, :ns_any then -0.5
          else 0 # :qname and :pi_target
          end
        end
      end

      # One alternative of a (possibly union) pattern.
      class Alternative
        attr_reader :steps, :separators, :source

        def initialize(source, steps, separators, absolute:, root_only: false)
          @source = source
          @steps = steps
          @separators = separators
          @absolute = absolute
          @root_only = root_only
        end

        def self.root(source)
          new(source, [], [], absolute: true, root_only: true)
        end

        def root_only?
          @root_only
        end

        def default_priority
          return 0.5 if @root_only
          return @steps[0].default_priority if @steps.size == 1
          0.5
        end

        def matches?(node)
          return node.is_a?(REXML::Document) if @root_only
          match_step?(@steps.size - 1, node)
        end

        private

        def match_step?(index, node)
          return false unless @steps[index].matches?(node)
          if index.zero?
            return true unless @absolute
            return Pattern.parent_of(node).is_a?(REXML::Document)
          end
          parent = Pattern.parent_of(node)
          return false if parent.nil?
          if @separators[index - 1] == :child
            match_step?(index - 1, parent)
          else
            ancestor = parent
            until ancestor.nil?
              return true if match_step?(index - 1, ancestor)
              ancestor = Pattern.parent_of(ancestor)
            end
            false
          end
        end
      end

      attr_reader :source, :alternatives

      def self.parse(source, namespaces = {})
        alternatives = split_union(source).map do |part|
          parse_alternative(part.strip, namespaces, source)
        end
        new(source, alternatives)
      end

      def initialize(source, alternatives)
        @source = source
        @alternatives = alternatives
      end

      # Returns the first alternative that matches +node+, or nil.
      def matching_alternative(node)
        @alternatives.find { |alternative| alternative.matches?(node) }
      end

      def matches?(node)
        !matching_alternative(node).nil?
      end

      # REXML::Document is a subclass of REXML::Element, but the root
      # node is not an element for pattern matching purposes.
      def self.element_node?(node)
        node.is_a?(REXML::Element) && !node.is_a?(REXML::Document)
      end

      # The parent of a node for pattern matching purposes; attributes
      # are parented at their owner element.
      def self.parent_of(node)
        case node
        when REXML::Attribute then node.element
        when REXML::Document then nil
        else node.parent
        end
      end

      # Splits a union pattern on top-level "|", respecting string
      # literals inside processing-instruction('...').
      def self.split_union(source)
        parts = []
        current = +""
        quote = nil
        source.each_char do |char|
          if quote
            quote = nil if char == quote
            current << char
          elsif char == "'" || char == '"'
            quote = char
            current << char
          elsif char == "|"
            parts << current
            current = +""
          else
            current << char
          end
        end
        parts << current
        parts
      end

      def self.parse_alternative(source, namespaces, full_source)
        if source.empty?
          raise PatternError, "empty pattern alternative in #{full_source.inspect}"
        end
        return Alternative.root(source) if source == "/"

        absolute = false
        rest = source
        if rest.start_with?("//")
          # "//a" is "/descendant-or-self::node()/child::a"; for matching
          # purposes that is equivalent to "a" anywhere in the tree.
          rest = rest[2..]
        elsif rest.start_with?("/")
          absolute = true
          rest = rest[1..]
        end

        tokens = rest.split(%r{(//|/)}).reject(&:empty?)
        if tokens.empty? || tokens.length.even?
          raise PatternError, "malformed pattern #{full_source.inspect}"
        end

        steps = []
        separators = []
        tokens.each_with_index do |token, index|
          if index.odd?
            separators << (token == "//" ? :descendant : :child)
          else
            steps << parse_step(token, namespaces, full_source)
          end
        end
        Alternative.new(source, steps, separators, absolute: absolute)
      end

      def self.parse_step(token, namespaces, full_source)
        axis = :child
        body = token
        if body.start_with?("@")
          axis = :attribute
          body = body[1..]
        elsif body.start_with?("attribute::")
          axis = :attribute
          body = body["attribute::".length..]
        elsif body.start_with?("child::")
          body = body["child::".length..]
        end

        test =
          case body
          when "node()" then [:type, :node]
          when "text()" then [:type, :text]
          when "comment()" then [:type, :comment]
          when "processing-instruction()" then [:type, :pi]
          when /\Aprocessing-instruction\(\s*(['"])(.*?)\1\s*\)\z/
            [:pi_target, Regexp.last_match(2)]
          when "*"
            [:any]
          when /\A(#{NCNAME}):\*\z/
            prefix = Regexp.last_match(1)
            uri = namespaces[prefix] or
              raise PatternError,
                    "unknown namespace prefix #{prefix.inspect} in pattern #{full_source.inspect}"
            [:ns_any, uri]
          when /\A(#{NCNAME})(?::(#{NCNAME}))?\z/
            prefix_or_name = Regexp.last_match(1)
            local = Regexp.last_match(2)
            if local
              uri = namespaces[prefix_or_name] or
                raise PatternError,
                      "unknown namespace prefix #{prefix_or_name.inspect} in pattern #{full_source.inspect}"
              [:qname, uri, local]
            else
              # An unprefixed QName in a pattern is in no namespace; the
              # default namespace does not apply (XSLT 1.0 section 5.2).
              [:qname, "", prefix_or_name]
            end
          else
            raise PatternError,
                  "unsupported step #{token.inspect} in pattern #{full_source.inspect}"
          end

        if axis == :attribute && (test[0] == :type || test[0] == :pi_target)
          raise PatternError,
                "node type test not allowed on the attribute axis in #{full_source.inspect}"
        end

        Step.new(axis, test, token)
      end
    end
  end
end
