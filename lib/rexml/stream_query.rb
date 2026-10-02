# frozen_string_literal: false

require "strscan"

require_relative "parseexception"
require_relative "parsers/pullparser"

module REXML
  # = Streaming XPath subset queries
  #
  # StreamQuery evaluates a small, well defined subset of XPath directly on
  # the REXML pull parser event stream.  It never builds a DOM tree, so it
  # can query documents that are too large to fit in memory:
  #
  #   query = REXML::StreamQuery.new("//x:item[@kind='book'][2]",
  #                                  namespaces: {"x" => "urn:shop"})
  #   query.each(io) do |match|
  #     p match.expanded_name   # => "x:item"
  #     p match.attributes      # => {"x:id" => "7", "kind" => "book", ...}
  #   end
  #
  # Results are yielded as StreamQuery::Match objects, always in document
  # order.
  #
  # == Supported expression subset
  #
  #   query    := separator? step (separator step)*
  #   separator:= "/" | "//"
  #   step     := name-test predicate*
  #   name-test:= "*" | qname | qname ":" qname   (prefix:local)
  #   predicate:= "[" "@" qname "=" literal "]"   (attribute equality)
  #             | "[" integer "]"                 (1-based position)
  #             | "[" "last()" "]"
  #
  # * A leading "/" ("//") selects children (descendants) of the document
  #   node.  A relative expression such as "a/b" is treated like "/a/b".
  # * "//" between steps is the descendant shortcut: any number of
  #   intermediate elements may appear between the two steps.
  # * Attribute equality predicates may be repeated and are combined with
  #   AND.  Both single and double quoted literals are supported.
  # * A position predicate ("[n]" or "[last()]") must be the last predicate
  #   of its step.  Positions are counted per parent element, exactly like
  #   the DOM XPath engine does.
  # * "last()" is only allowed on the final step of the expression.
  # * Namespace prefixes used in the expression must be bound through the
  #   +namespaces+ option, mirroring REXML::XPath.  An unprefixed name test
  #   only matches elements without a namespace, and an unprefixed
  #   attribute name only matches attributes without a namespace.
  #
  # Anything else (functions other than last(), axes such as ".." or
  # "ancestor::", "text()", unions, comparisons other than attribute
  # equality, nested paths inside predicates, ...) is rejected with
  # REXML::ParseException when the query is built, before any parsing
  # starts.
  #
  # == Memory behavior
  #
  # Only the currently open elements, one matcher context per open element
  # per step, and -- for expressions ending in "last()" -- the current
  # candidate per open context are kept in memory.  Queries without
  # "last()" emit matches as soon as the matching start tag is seen and
  # buffer nothing at all.  The document as a whole is never retained.
  #
  # When the consumer stops early (for example with +break+), all query
  # state is released before StreamQuery#each returns.
  class StreamQuery
    # A single streaming query result.
    #
    # A Match describes the start tag of a matched element.  It deliberately
    # does not expose children or text: streaming queries never buffer the
    # subtree of a match.
    class Match
      # The local name of the element, without any namespace prefix.
      attr_reader :name
      # The namespace prefix as written in the document, or nil.
      attr_reader :prefix
      # The qualified name as written in the document ("prefix:local").
      attr_reader :expanded_name
      # The namespace URI of the element, or nil when it has none.
      attr_reader :namespace
      # A Hash of qualified attribute name => value, as written in the
      # document.  Namespace declarations ("xmlns", "xmlns:prefix") are
      # included, mirroring REXML::Element#attributes.
      attr_reader :attributes
      # The depth of the element in the document.  The root element has
      # depth 1.
      attr_reader :depth

      def initialize(expanded_name, namespace, attributes, depth) # :nodoc:
        @expanded_name = expanded_name
        @prefix, @name = expanded_name.split(":", 2)
        unless @name
          @name = @prefix
          @prefix = nil
        end
        @namespace = namespace
        @attributes = attributes
        @depth = depth
      end

      def ==(other)
        other.kind_of?(Match) and
          expanded_name == other.expanded_name and
          namespace == other.namespace and
          attributes == other.attributes
      end

      def inspect
        "#<REXML::StreamQuery::Match #{expanded_name.inspect} " +          "ns=#{namespace.inspect} attrs=#{attributes.inspect} depth=#{depth}>"
      end
    end

    # One parsed step of the supported expression subset.
    class Step # :nodoc:
      attr_reader :axis

      def initialize(axis, any, prefix, local_name, namespace, predicates)
        @axis = axis               # :child or :descendant
        @any = any                 # true for "*"
        @prefix = prefix           # String or nil
        @local_name = local_name   # String or nil when @any
        @namespace = namespace     # resolved URI for prefixed tests, else nil
        @predicates = predicates
      end

      def descendant?
        @axis == :descendant
      end

      def last?
        @predicates.any? {|predicate| predicate[0] == :last}
      end

      def positional?
        @predicates.any? do |predicate|
          predicate[0] == :last or predicate[0] == :position
        end
      end

      def position
        predicate = @predicates.find {|candidate| candidate[0] == :position}
        predicate && predicate[1]
      end

      def name_match?(element_namespace, element_local_name)
        return true if @any
        return false unless element_local_name == @local_name
        if @prefix
          element_namespace == @namespace
        else
          element_namespace.nil?
        end
      end

      def attribute_predicates
        @predicates.select {|predicate| predicate[0] == :attribute}
      end
    end

    # Parses and validates the supported expression subset.  Anything
    # outside of the subset is rejected before the query starts, so a
    # StreamQuery never silently returns wrong results for an expression it
    # does not understand.
    class ExpressionParser # :nodoc:
      NCNAME = /[[:alpha:]_][-[:alnum:]_.]*/

      def initialize(namespaces)
        @namespaces = namespaces || {}
      end

      def parse(expression)
        unless expression.is_a?(String) and not expression.strip.empty?
          raise unsupported(expression, "expression must be a non-empty String")
        end
        scanner = StringScanner.new(expression)
        steps = []
        axis = scan_separator(scanner) || :child
        loop do
          if scanner.eos?
            raise unsupported(expression, "missing step")
          end
          steps << parse_step(scanner, axis, expression)
          separator = scan_separator(scanner)
          break unless separator
          axis = separator
        end
        unless scanner.eos?
          raise unsupported(expression,
                              "unexpected #{scanner.rest.inspect}")
        end
        validate(steps, expression)
        steps
      end

      private

      def scan_separator(scanner)
        scanner.skip(/\s+/)
        if scanner.scan(%r{//})
          :descendant
        elsif scanner.scan(%r{/})
          :child
        end
      end

      def parse_step(scanner, axis, expression)
        scanner.skip(/\s+/)
        any = false
        prefix = nil
        local_name = nil
        if scanner.scan(/\*/)
          any = true
        elsif (token = scanner.scan(NCNAME))
          if scanner.scan(/:/)
            local_name = scanner.scan(NCNAME)
            unless local_name
              raise unsupported(expression, "expected a local name after ':'")
            end
            prefix = token
          else
            local_name = token
          end
        else
          raise unsupported(expression, "expected an element name or '*'")
        end
        predicates = []
        loop do
          scanner.skip(/\s+/)
          break unless scanner.scan(/\[/)
          if predicates.any? {|predicate| positional_predicate?(predicate)}
            raise unsupported(
              expression,
              "a position predicate must be the last predicate of a step")
          end
          predicates << parse_predicate(scanner, expression)
          scanner.skip(/\s+/)
          unless scanner.scan(/\]/)
            raise unsupported(expression, "expected ']'")
          end
        end
        namespace = resolve_prefix(prefix, expression)
        Step.new(axis, any, prefix, local_name, namespace, predicates)
      end

      def parse_predicate(scanner, expression)
        scanner.skip(/\s+/)
        if scanner.scan(/@/)
          scanner.skip(/\s+/)
          token = scanner.scan(NCNAME)
          unless token
            raise unsupported(expression,
                                "expected an attribute name after '@'")
          end
          prefix = nil
          local_name = token
          if scanner.scan(/:/)
            local_name = scanner.scan(NCNAME)
            unless local_name
              raise unsupported(expression, "expected a local name after ':'")
            end
            prefix = token
          end
          scanner.skip(/\s+/)
          unless scanner.scan(/=/)
            raise unsupported(
              expression, "only equality is supported in attribute predicates")
          end
          scanner.skip(/\s+/)
          unless scanner.scan(/'([^']*)'|"([^"]*)"/)
            raise unsupported(expression, "expected a quoted string literal")
          end
          value = scanner[1] || scanner[2] || ""
          namespace = resolve_prefix(prefix, expression)
          [:attribute, prefix, local_name, namespace, value]
        elsif scanner.scan(/last\s*\(\s*\)/)
          [:last]
        elsif scanner.scan(/\d+/)
          position = scanner.matched.to_i
          if position < 1
            raise unsupported(expression, "positions start at 1")
          end
          [:position, position]
        else
          raise unsupported(
            expression,
            "only [@name='value'], [n] and [last()] predicates are supported")
        end
      end

      def positional_predicate?(predicate)
        predicate[0] == :last or predicate[0] == :position
      end

      def resolve_prefix(prefix, expression)
        return nil unless prefix
        namespace = @namespaces[prefix]
        unless namespace
          raise unsupported(expression,
                              "undefined namespace prefix #{prefix.inspect}")
        end
        namespace
      end

      def validate(steps, expression)
        steps[0..-2].each do |step|
          if step.last?
            raise unsupported(expression,
                                "last() is only supported on the final step")
          end
        end
      end

      def unsupported(expression, detail)
        message = "Unsupported streaming query expression " +                  "(#{detail}): #{expression.inspect}"
        ParseException.new(message)
      end
    end

    # The expression given to ::new.
    attr_reader :expression

    # Creates a streaming query for +expression+.
    #
    # +namespaces+ maps prefixes used in the expression to namespace URIs,
    # exactly like the namespaces argument of REXML::XPath.  The expression
    # is parsed and validated immediately: unsupported expressions raise
    # REXML::ParseException here, before any document is consumed.
    def initialize(expression, namespaces: nil)
      @expression = expression
      @steps = ExpressionParser.new(namespaces).parse(expression)
      @deferred = @steps.last.last?
    end

    # Convenience shortcut for
    # <tt>StreamQuery.new(expression, ...).each(source)</tt>.
    def self.each(source, expression, namespaces: nil, &block)
      new(expression, namespaces: namespaces).each(source, &block)
    end

    # Evaluates the query against +source+, yielding each Match in document
    # order.
    #
    # +source+ may be a String or any IO-like object; it is consumed
    # incrementally through the pull parser, so arbitrarily large documents
    # and arbitrarily small read chunks are fine.
    #
    # Without a block, an Enumerator is returned.  When the block stops the
    # iteration early (for example with +break+), all query state is
    # released before this method returns.
    def each(source)
      return to_enum(__method__, source) unless block_given?
      session = Session.new(@steps, @deferred)
      begin
        session.run(source) {|match| yield match}
      ensure
        session.close
      end
      self
    end

    # Drives the pull parser and the step matchers for a single #each call.
    # All mutable state lives here, so a StreamQuery instance itself is
    # stateless and can be reused, and abandoning a session (early break,
    # exception) leaves nothing behind once #close has run.
    class Session # :nodoc:
      Frame = Struct.new(:depth)

      def initialize(steps, deferred)
        @steps = steps
        @deferred = deferred
        @document_frame = Frame.new(0)
        @element_stack = []
        @matched = Array.new(steps.size) {[]}
        @contexts = Array.new(steps.size) do |index|
          steps[index].positional? ? {} : nil
        end
        @ns_scope = {"xml" => "http://www.w3.org/XML/1998/namespace"}
        @ns_restore = []
        @event_index = 0
        @pending = {}
      end

      def run(source)
        parser = REXML::Parsers::PullParser.new(source)
        while parser.has_next?
          event = parser.pull
          case event.event_type
          when :start_element
            handle_start(event[0], event[1]) {|match| yield match}
          when :end_element
            handle_end {|match| yield match}
          when :end_document
            finish {|match| yield match}
          end
        end
      end

      def close
        @element_stack.clear
        @matched.each(&:clear)
        @contexts.each {|contexts| contexts&.clear}
        @ns_scope.clear
        @ns_restore.clear
        @pending.clear
      end

      private

      def handle_start(qname, attributes)
        @event_index += 1
        depth = @element_stack.size + 1
        push_namespaces(attributes)
        prefix, local_name = split_qname(qname)
        namespace = prefix ? @ns_scope[prefix] : @ns_scope[""]
        parent_frame = @element_stack.last || @document_frame
        matched_steps = []
        @steps.each_with_index do |step, index|
          next unless parent_eligible?(step, index, parent_frame)
          next unless step.name_match?(namespace, local_name)
          next unless attributes_match?(step, attributes)
          next unless position_accepted?(step, index, parent_frame,
                                         qname, namespace, attributes, depth)
          if index == @steps.size - 1
            yield Match.new(qname, namespace, attributes.dup, depth)
          else
            matched_steps << index
          end
        end
        frame = Frame.new(depth)
        matched_steps.each {|index| @matched[index].push(frame)}
        @element_stack.push(frame)
      end

      def handle_end
        frame = @element_stack.pop
        pop_namespaces
        @steps.each_with_index do |step, index|
          @matched[index].pop if @matched[index].last.equal?(frame)
          contexts = @contexts[index]
          next unless contexts
          context = contexts.delete(frame)
          next unless context
          buffered = context[:buffered]
          if buffered and index == @steps.size - 1
            qname, namespace, attributes, depth, event_index = buffered
            @pending[event_index] =
              Match.new(qname, namespace, attributes.dup, depth)
          end
        end
        flush_pending {|match| yield match} if @deferred
      end

      def finish
        @pending.keys.sort.each do |event_index|
          yield @pending.delete(event_index)
        end
      end

      def parent_eligible?(step, index, parent_frame)
        if index.zero?
          step.descendant? or parent_frame.equal?(@document_frame)
        elsif step.descendant?
          not @matched[index - 1].empty?
        else
          @matched[index - 1].last.equal?(parent_frame)
        end
      end

      def attributes_match?(step, attributes)
        step.attribute_predicates.all? do |_, prefix, local_name, ns, value|
          if prefix
            attributes.any? do |key, attribute_value|
              next false unless attribute_value == value
              attribute_prefix, attribute_local = split_qname(key)
              attribute_prefix and attribute_local == local_name and
                @ns_scope[attribute_prefix] == ns
            end
          else
            local_name != "xmlns" and attributes[local_name] == value
          end
        end
      end

      def position_accepted?(step, index, parent_frame,
                             qname, namespace, attributes, depth)
        return true unless step.positional?
        context = (@contexts[index][parent_frame] ||=
                     {:count => 0, :buffered => nil})
        context[:count] += 1
        if step.last?
          context[:buffered] =
            [qname, namespace, attributes, depth, @event_index]
          false
        else
          context[:count] == step.position
        end
      end

      # Emits finalized last() results in document order.  A buffered
      # candidate of a still open context may be displaced by a later
      # sibling, so pending results may only be emitted up to the smallest
      # event index that can still change.
      def flush_pending
        return if @pending.empty?
        threshold = @event_index + 1
        contexts = @contexts[@steps.size - 1]
        if contexts
          contexts.each_value do |context|
            buffered = context[:buffered]
            threshold = buffered[4] if buffered and buffered[4] < threshold
          end
        end
        @pending.keys.sort.each do |event_index|
          break unless event_index < threshold
          yield @pending.delete(event_index)
        end
      end

      def push_namespaces(attributes)
        restore = {}
        attributes.each do |key, value|
          if key == "xmlns"
            restore[""] = @ns_scope[""]
            @ns_scope[""] = value
          elsif key.start_with?("xmlns:")
            prefix = key[6..-1]
            restore[prefix] = @ns_scope[prefix]
            @ns_scope[prefix] = value
          end
        end
        @ns_restore.push(restore)
      end

      def pop_namespaces
        @ns_restore.pop.each do |prefix, old_value|
          if old_value.nil?
            @ns_scope.delete(prefix)
          else
            @ns_scope[prefix] = old_value
          end
        end
      end

      def split_qname(qname)
        if qname.include?(":")
          qname.split(":", 2)
        else
          [nil, qname]
        end
      end
    end
    private_constant :Session
  end
end
