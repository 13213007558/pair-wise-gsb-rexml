# frozen_string_literal: false

require "rexml/document"

module REXMLTests
  class TestXPathExtensionFunctions < Test::Unit::TestCase
    XML = <<~XML
      <root xmlns:service="urn:service-a" xmlns:other="urn:service-b">
        <group>
          <item id="a">10</item>
          <item id="b">20</item>
          <item id="c">30</item>
        </group>
      </root>
    XML

    def setup
      @document = REXML::Document.new(XML)
    end

    def test_context_registers_functions_by_namespace_uri_and_local_name
      context_a = REXML::XPath::Context.new(namespaces: {"service" => "urn:service-a"})
      context_b = REXML::XPath::Context.new(namespaces: {"service" => "urn:service-b"})
      context_a.register_function("urn:service-a", "value", proc { "A-value" },
                                  return_type: :string)
      context_b.register_function("urn:service-b", "value", proc { "B-value" },
                                  return_type: :string)

      assert_equal(["A-value"], REXML::XPath.match(@document, "service:value()",
                                               nil, {}, context: context_a))
      assert_equal(["B-value"], REXML::XPath.match(@document, "service:value()",
                                               nil, {}, context: context_b))
    end

    def test_context_exposes_current_node_position_and_size
      seen = []
      context = REXML::XPath::Context.new(namespaces: {"service" => "urn:service-a"})
      context.register_function("urn:service-a", "info") do |context|
        seen << [context.node.attribute("id").value, context.position, context.size]
        true
      end

      REXML::XPath.match(@document, "//item[service:info()]", nil, {}, context: context)

      assert_equal([["a", 1, 3], ["b", 2, 3], ["c", 3, 3]], seen)
    end

    def test_unprefixed_function_uses_local_name_registration
      context = REXML::XPath::Context.new
      context.register_function("", "my_value") { "registered" }

      assert_equal(["registered"], REXML::XPath.match(@document, "my_value()",
                                                   nil, {}, context: context))
    end

    def test_declared_arguments_and_return_type_are_xpath_coerced
      context = REXML::XPath::Context.new(namespaces: {"service" => "urn:service-a"})
      context.register_function("urn:service-a", "add-ten",
                                ->(context, value) { value + 10 },
                                arguments: [:number], return: :number)

      assert_equal([17.5], REXML::XPath.match(@document, "//item[@id='a'][service:add-ten('7.5')=17.5]",
                                              nil, {}, context: context).map { |item| item.text.to_f + 7.5 })
    end

    def test_node_set_returns_are_sorted_and_deduplicated
      items = REXML::XPath.match(@document, "//item")
      context = REXML::XPath::Context.new(namespaces: {"service" => "urn:service-a"})
      context.register_function("urn:service-a", "pick") do |context, nodes|
        [nodes[2], nodes[0], nodes[1], nodes[0]]
      end

      result = REXML::XPath.match(@document,
                                  "service:pick(//item)",
                                  nil,
                                  {},
                                  context: context)

      assert_equal(items, result)
    end

    def test_nested_query_restores_outer_context
      context = REXML::XPath::Context.new(namespaces: {"service" => "urn:service-a"})
      parser = REXML::XPathParser.new(context: context)
      restored = []
      inner_nodes = []
      context.register_function("urn:service-a", "nested") do |context|
        inner_nodes << parser.parse("item[last()]", context.node).map(&:name)
        restored << [context.node.name, context.position, context.size]
        true
      end

      result = parser.parse("//group[service:nested()]/item[2]", @document)

      assert_equal([["group", 1, 1]], restored)
      assert_equal([["item"]], inner_nodes)
      assert_equal([@document.root.elements["//group/item[2]"]], result)
    end

    def test_scalar_results_cannot_be_coerced_with_to_s
      context = REXML::XPath::Context.new(namespaces: {"service" => "urn:service-a"})
      context.register_function("urn:service-a", "bad") { |context| Object.new }

      assert_raise(TypeError) do
        REXML::XPath.match(@document, "service:bad()", nil, {}, context: context)
      end
    end

    def test_declared_node_set_arguments_are_sorted_and_deduplicated
      context = REXML::XPath::Context.new(namespaces: {"service" => "urn:service-a"})
      seen = nil
      context.register_function("urn:service-a", "first-id") do |context, nodes|
        seen = nodes
        nodes.first.attribute("id").value
      end

      result = REXML::XPath.match(@document,
                                  "//item[service:first-id(//item | //item[1])='a']",
                                  nil,
                                  {},
                                  context: context)

      assert_equal(REXML::XPath.match(@document, "//item"), seen)
      assert_equal(REXML::XPath.match(@document, "//item"), result)
    end

    def test_declared_string_arguments_reject_non_xpath_values
      context = REXML::XPath::Context.new(namespaces: {"service" => "urn:service-a"})
      context.register_function("urn:service-a", "identity",
                                ->(context, value) { value },
                                parameters: [:string], returns: :string)

      assert_raise(TypeError) do
        context.functions["urn:service-a", "identity"].call(
          [Object.new],
          REXML::XPath::FunctionContext.new(node: @document.root, position: 1, size: 1),
          REXML::FunctionsClass.new
        )
      end
    end

    def test_same_lexical_name_is_isolated_between_thread_contexts
      results = {}
      mutex = Mutex.new

      threads = [
        ["urn:service-a", "A"],
        ["urn:service-b", "B"]
      ].map do |namespace_uri, marker|
        Thread.new do
          context = REXML::XPath::Context.new(namespaces: {"service" => namespace_uri})
          context.register_function(namespace_uri, "same") { marker }
          result = REXML::XPath.match(@document,
                                     "service:same()",
                                     nil,
                                     {},
                                     context: context)
          mutex.synchronize { results[namespace_uri] = result }
        end
      end
      threads.each(&:join)

      assert_equal(["A"], results["urn:service-a"])
      assert_equal(["B"], results["urn:service-b"])
    end
  end
end
