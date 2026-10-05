# frozen_string_literal: true

require_relative "../helper"

module REXMLTests
  class TestXPathExtensionFunctions < Test::Unit::TestCase
    include REXML

    def test_context_registry_is_not_shared
      first_context = XPath::Context.new
      second_context = XPath::Context.new
      first_context.register_function("urn:service", "value") do |context|
        context.node.attributes["id"]
      end
      second_context.register_function("urn:other", "value") { "other" }

      doc = Document.new("<root><item id='one'/><item id='two'/></root>")
      namespaces = {"svc" => "urn:service"}

      assert_equal(doc.root.elements.to_a("item"),
                   XPath.match(doc, "//item[svc:value()]", namespaces, {},
                               context: first_context))
      other_namespaces = {"svc" => "urn:other"}
      assert_equal(["other"],
                   XPath.match(doc, "svc:value()", other_namespaces, {},
                               context: second_context))
    end

    def test_unprefixed_extension_uses_empty_namespace
      context = XPath::Context.new
      context.register_function("", "service-value", return_type: :string) do
        "local"
      end
      context.register_function("", "service_value", return_type: :string) do
        "underscored"
      end
      doc = Document.new("<root/>")

      assert_equal(["local"],
                   XPath.match(doc, "service-value()", nil, {}, context: context))
      assert_equal(["underscored"],
                   XPath.match(doc, "service_value()", nil, {}, context: context))
    end

    def test_unknown_prefixed_extension_does_not_match_unprefixed_function
      doc = Document.new("<root><a/></root>")

      assert_empty(XPath.match(doc, "svc:value()", {"svc" => "urn:missing"}))
    end

    def test_declared_scalar_arguments_and_result
      context = XPath::Context.new
      context.register_function("urn:service", "add", :number, :number,
                                return_type: :number) do |_context, first, second|
        first + second
      end
      doc = Document.new("<root><item value='2'>3</item></root>")

      assert_equal([5.0],
                   XPath.match(doc, "svc:add('2', '3')",
                               {"svc" => "urn:service"}, {}, context: context))
      assert_equal(doc.root.elements.to_a("item"),
                   XPath.match(doc, "//item[svc:add(@value, text()) = 5.0]",
                               {"svc" => "urn:service"}, {}, context: context))
      assert_equal([], XPath.match(doc, "//item[svc:add(@value, text()) = 6]",
                                   {"svc" => "urn:service"}, {}, context: context))
    end

    def test_string_result_does_not_accept_arbitrary_to_s
      context = XPath::Context.new
      context.register_function("urn:service", "bad", return_type: :string) do
        Object.new
      end
      doc = Document.new("<root/>")

      assert_raise(TypeError) do
        XPath.match(doc, "svc:bad()", {"svc" => "urn:service"}, {}, context: context)
      end
    end

    def test_undeclared_result_must_be_xpath_value
      context = XPath::Context.new
      context.register_function("urn:service", "bad") { Object.new }
      doc = Document.new("<root/>")

      assert_raise(TypeError) do
        XPath.match(doc, "svc:bad()", {"svc" => "urn:service"}, {}, context: context)
      end
    end

    def test_declared_argument_types_are_validated
      context = XPath::Context.new
      seen = nil
      context.register_function("urn:service", "nodes", :node_set) do |_context, nodes|
        seen = nodes
        true
      end
      doc = Document.new("<root><a/><a/></root>")

      assert_equal(2, XPath.match(doc, "//a[svc:nodes(. | //a)]",
                                  {"svc" => "urn:service"}, {},
                                  context: context).size)
      assert_equal(doc.root.elements.to_a("a"), seen)
      assert_raise(TypeError) do
        XPath.match(doc, "svc:nodes('not-a-node-set')",
                    {"svc" => "urn:service"}, {}, context: context)
      end
    end

    def test_function_context
      observed = []
      context = XPath::Context.new
      context.register_function("urn:service", "where",
                                return_type: :number) do |function_context|
        observed << [function_context.node.attributes["id"], function_context.position,
                     function_context.size, function_context.current_node,
                     function_context.last]
        1
      end
      doc = Document.new("<root><item id='a'/><item id='b'/></root>")

      XPath.match(doc, "//item[svc:where()]",
                 {"svc" => "urn:service"}, {}, context: context)

      assert_equal([["a", 1, 2], ["b", 2, 2]],
                   observed.map { |node, position, size, current_node, last|
                     [node, position, size] if current_node.attributes["id"] == node && last == size
                   })
    end

    def test_node_set_result_is_sorted_and_deduplicated
      context = XPath::Context.new
      context.register_function("urn:service", "items",
                                return_type: :node_set) do |function_context|
        root = function_context.node.root
        second = root.elements.to_a("c")[1]
        first = root.elements.to_a("c")[0]
        [second, second, first]
      end
      doc = Document.new("<root><c id='first'/><c id='second'/></root>")

      result = XPath.match(doc, "svc:items()", {"svc" => "urn:service"}, {},
                           context: context)

      assert_equal(["first", "second"], result.map { |node| node.attributes["id"] })
      assert_equal(2, result.size)
    end

    def test_nested_query_restores_outer_context
      outer_nodes = []
      parser = XPathParser.new
      context = XPath::Context.new
      context.register_function("urn:service", "outer") do |function_context|
        outer_nodes << [function_context.position, function_context.node.attributes["id"]]
        parser.parse("//child[svc:inner()]", function_context.node)
        function_context.position
      end
      context.register_function("urn:service", "inner") do |function_context|
        function_context.node.attributes["keep"] == "true"
      end
      doc = Document.new("<root><item id='a'><child keep='true'/></item>" \
                         "<item id='b'><child keep='false'/></item></root>")

      parser.namespaces = {"svc" => "urn:service"}
      parser.query_context = context
      result = parser.parse("//item[svc:outer()]", doc)

      assert_equal(["a", "b"], result.map { |node| node.attributes["id"] })
      assert_equal([[1, "a"], [2, "b"]], outer_nodes)
    end

    def test_same_lexical_name_in_two_threads
      threads = 2.times.map do |index|
        Thread.new do
          result = nil
          Thread.pass
          context = XPath::Context.new
          context.register_function("urn:service", "value", return_type: :string) do
            "service-#{index}"
          end
          doc = Document.new("<root/>")
          result = XPath.match(doc, "svc:value()", {"svc" => "urn:service"}, {},
                               context: context).first
          [result, context]
        end
      end
      results = threads.map(&:value)

      assert_equal(["service-0", "service-1"], results.map(&:first).sort)
      assert_not_same(results[0][1], results[1][1])
      assert_not_send([Functions, :extension?, "urn:service", "value"])
    end
  end
end
