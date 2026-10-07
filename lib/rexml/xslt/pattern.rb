# frozen_string_literal: true

module REXML
  module XSLT
    class PatternError < Error
    end

    class Pattern
      Step = Struct.new(:kind, :name, :axis, :predicate, :descendant, :default_priority, keyword_init: true)
      Branch = Struct.new(:source, :absolute, :steps, :default_priority, keyword_init: true)

      attr_reader :source, :branches

      def self.parse(source, namespaces)
        new(source, namespaces)
      end

      def initialize(source, namespaces)
        @source = source.to_s.strip.dup
        @namespaces = namespaces || {}
        @branches = split_union(@source).map { |branch| parse_branch(branch) }
      end

      def default_priority
        values = branches.collect(&:default_priority).uniq
        values.size == 1 ? values.first : 0.5
      end

      def xpaths
        branches.flat_map { |branch| branch_xpaths(branch) }
      end

      def matches_document?
        branches.any? { |branch| branch.source == "/" }
      end

      private

      def split_union(expression)
        branches = []
        buffer = +""
        depth = 0
        quote = nil
        index = 0
        while index < expression.length
          character = expression[index]
          if quote
            buffer << character
            quote = nil if character == quote
          elsif character == "'" || character == '"'
            quote = character
            buffer << character
          elsif character == "["
            depth += 1
            buffer << character
          elsif character == "]"
            raise PatternError, "Unbalanced predicate in pattern: #{expression}" if depth.zero?
            depth -= 1
            buffer << character
          elsif character == "|" && depth.zero?
            add_branch(branches, buffer)
            buffer = +""
          else
            buffer << character
          end
          index += 1
        end
        raise PatternError, "Unbalanced predicate in pattern: #{expression}" unless depth.zero? && quote.nil?
        add_branch(branches, buffer)
        branches
      end

      def add_branch(branches, source)
        source = source.strip
        raise PatternError, "Empty union branch in pattern: #{@source}" if source.empty?
        branches << source
      end

      def parse_branch(source)
        if source == "/"
          return Branch.new(source: source, absolute: true, steps: [], default_priority: 0.5)
        end

        absolute = source.start_with?("/")
        path = absolute ? source[1..-1] : source
        leading_descendant = path.start_with?("/")
        path = path[2..-1] if leading_descendant
        tokens = split_steps(path, leading_descendant)
        raise PatternError, "Invalid pattern: #{source}" if tokens.empty?
        steps = tokens.collect { |token| parse_step(token) }
        Branch.new(
          source: source,
          absolute: absolute,
          steps: steps,
          default_priority: branch_priority(steps)
        )
      end

      def split_steps(path, descendant = false)
        steps = []
        buffer = +""
        depth = 0
        quote = nil
        index = 0
        while index < path.length
          character = path[index]
          if quote
            buffer << character
            quote = nil if character == quote
          elsif character == "'" || character == '"'
            quote = character
            buffer << character
          elsif character == "["
            depth += 1
            buffer << character
          elsif character == "]"
            depth -= 1
            buffer << character
          elsif depth.zero? && character == "/"
            if path[index + 1] == "/"
              add_step_token(steps, buffer, descendant)
              buffer = +""
              descendant = true
              index += 1
            elsif descendant && buffer.empty?
              descendant = true
            else
              add_step_token(steps, buffer, descendant)
              buffer = +""
              descendant = false
            end
          else
            buffer << character
          end
          index += 1
        end
        add_step_token(steps, buffer, descendant)
        steps
      end

      def add_step_token(steps, buffer, descendant)
        token = buffer.strip
        return if token.empty? && !descendant
        raise PatternError, "Invalid descendant step in pattern: #{@source}" if token.empty?
        steps << {descendant: descendant, token: token}
      end

      def parse_step(entry)
        token = entry[:token]
        axis = :child
        predicate = nil
        if token.include?("[")
          raise PatternError, "Predicate must be at the end of step: #{token}" unless token =~ /\A([^\[]+)\[(.+)\]\z/m
          token = $1
          predicate = $2
          raise PatternError, "Nested predicates are not supported: #{entry[:token]}" if predicate.include?("[")
        end

        if token.include?("::")
          axis_name, node_test = token.split("::", 2)
          axis = axis_name.strip.to_sym
          unless [:child, :attribute].include?(axis)
            raise PatternError, "Unsupported pattern axis: #{axis_name}"
          end
        elsif token.start_with?("@")
          axis = :attribute
          node_test = token[1..-1]
        else
          node_test = token
        end

        kind, name = parse_node_test(node_test, axis)
        Step.new(
          kind: kind,
          name: name,
          axis: axis,
          predicate: predicate,
          descendant: entry[:descendant],
          default_priority: step_priority(kind, name, axis, predicate)
        )
      end

      def parse_node_test(node_test, axis)
        node_test = node_test.strip
        case node_test
        when "*"
          [:name, "*"]
        when /\A([\w.-]+):\*\z/
          prefix = $1
          uri = @namespaces[prefix]
          raise PatternError, "Unbound namespace prefix in pattern: #{prefix}:" if uri.nil?
          [:name, "{#{uri}}*"]
        when "node()", "text()", "comment()", "processing-instruction()"
          [:node_type, node_test.delete("()")]
        when /\Aprocessing-instruction\((['"])([^'"]+)\1\)\z/
          [:processing_instruction, $2]
        when /\A(?:([\w.-]+):)?([\w.-]+)\z/
          [:name, expanded_name($1, $2, axis)]
        else
          raise PatternError, "Unsupported node test in pattern: #{node_test}"
        end
      end

      def expanded_name(prefix, local_name, axis)
        if prefix
          uri = @namespaces[prefix]
          if uri.nil?
            raise PatternError, "Unbound namespace prefix in pattern: #{prefix}:"
          end
          "{#{uri}}#{local_name}"
        elsif axis == :attribute
          local_name
        else
          "{}#{local_name}"
        end
      end

      def step_priority(kind, name, axis, predicate)
        if predicate
          0.5
        elsif kind == :node_type
          -0.5
        elsif kind == :processing_instruction
          0.0
        elsif name&.end_with?("}*")
          -0.25
        elsif name == "*"
          -0.5
        elsif axis == :attribute && !name.start_with?("{")
          0.0
        else
          0.0
        end
      end

      def branch_priority(steps)
        return 0.5 if steps.size > 1
        steps.first.descendant ? 0.5 : steps.first.default_priority
      end

      def branch_xpaths(branch)
        return ["/"] if branch.source == "/"
        path = branch.absolute ? branch.source : "//" + branch.source
        last = branch.steps.last
        return [path] unless last.kind == :node_type && last.name == "node"
        %w[* text() comment() processing-instruction()].collect do |node_test|
          path.sub(/node\(\)\z/, node_test)
        end
      end

      def step_xpath(step)
        test =
          case step.kind
          when :name
            if step.name == "*"
              "*"
            elsif step.name.start_with?("{")
              uri, local_name = step.name[1..-1].split("}", 2)
              if local_name == "*"
                prefix = xpath_prefix(uri)
                raise PatternError, "Unbound namespace prefix in pattern" if prefix.nil?
                "#{prefix}:*"
              else
                prefix = xpath_prefix(uri)
                prefix ? "#{prefix}:#{local_name}" : local_name
              end
            else
              step.name
            end
          when :processing_instruction
            "processing-instruction('#{step.name}')"
          else
            "#{step.name}()"
          end
        axis = step.axis == :attribute ? "@" : ""
        axis + test + (step.predicate ? "[#{step.predicate}]" : "")
      end

      def xpath_prefix(uri)
        @namespaces.key(uri)
      end
    end
  end
end
