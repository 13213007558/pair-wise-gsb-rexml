# frozen_string_literal: true

module REXMLTests
  class TestXPathExtensionFunctions < Test::Unit::TestCase
    NAMESPACES = {
      "a" => "urn:tenant-a",
      "b" => "urn:tenant-b"
    }

    def setup
      @document = REXML::Document.new(<<-XML)
<root xmlns:a="urn:tenant-a" xmlns:b="urn:tenant-b">
  <item value="10"/>
  <item value="20"/>
  <item value="30"/>
</root>
      XML
    end

    def test_same_local_name_uses_namespace_uri
      functions = {
        "urn:tenant-a" => {
          "score" => ->(items) { items.sum { |item| item.attribute("value").to_s.to_i } }
        },
        "urn:tenant-b" => {
          "score" => ->(items) { items.size }
        }
      }

      assert_equal([60], REXML::XPath.match(@document, "a:score(//item)", NAMESPACES, {}, functions:))
      assert_equal([3], REXML::XPath.match(@document, "b:score(//item)", NAMESPACES, {}, functions:))
    end

    def test_prefix_uses_context_namespace_without_namespace_argument
      function = ->(items) { items.size }
      functions = {"urn:tenant-a" => {"score" => function}}

      assert_equal([3], REXML::XPath.match(@document, "a:score(//item)", nil, {}, functions:))
    end

    def test_flat_function_key
      function = ->(value) { REXML::Functions.number(value) * 2 }
      functions = {["urn:tenant-a", "double"] => function}

      assert_equal([20],
                   REXML::XPath.match(@document,
                                      "a:double(string(//item[1]/@value))",
                                      NAMESPACES,
                                      {},
                                      functions:))
    end

    def test_function_arguments_and_results_use_xpath_types
      received_arguments = nil
      functions = {
        "urn:tenant-a" => {
          "types" => ->(items, number, string, flag) {
            received_arguments = [items, number, string, flag]
            0
          }
        }
      }
      REXML::XPath.match(@document,
                         "a:types(//item, 1, 'two', true())",
                         NAMESPACES,
                         {},
                         functions:)

      items, number, string, flag = received_arguments
      assert_equal(3, items.size)
      assert(items.all?(REXML::Node))
      assert_equal([Integer, 1, "two", true], [number.class, number, string, flag])
    end

    def test_node_set_result_can_be_filtered_by_xpath
      function = ->(items) { items.select { |item| item.attribute("value").to_s.to_i > 15 } }
      functions = {"urn:tenant-a" => {"large" => function}}

      items = REXML::XPath.match(@document, "a:large(//item)/@value", NAMESPACES, {}, functions:)
      assert_equal(%w[20 30], items.collect(&:value))
    end

    def test_registration_does_not_modify_global_functions
      function = ->(items) { items.size }
      functions = {"urn:tenant-a" => {"score" => function}}

      REXML::XPath.match(@document, "a:score(//item)", NAMESPACES, {}, functions:)

      assert_not_respond_to(REXML::Functions, :score)
      assert_equal(false, REXML::Functions.call("score", args: [[]], fallback: false))
    end

    def test_unknown_function
      assert_raise(REXML::XPath::UndefinedFunction) do
        REXML::XPath.match(@document, "a:missing(//item)", NAMESPACES, {}, functions: {})
      end
    end

    def test_unknown_prefix
      assert_raise(REXML::UndefinedNamespaceException) do
        REXML::XPath.match(@document,
                            "missing:score(//item)",
                            {"missing" => nil},
                            {},
                            functions: {})
      end
    end

    def test_wrong_number_of_arguments
      functions = {"urn:tenant-a" => {"score" => ->(items) { items.size }}}

      assert_raise(REXML::XPath::WrongNumberOfArguments) do
        REXML::XPath.match(@document, "a:score()", NAMESPACES, {}, functions:)
      end
    end

    def test_builtin_wrong_number_of_arguments
      assert_raise(REXML::XPath::WrongNumberOfArguments) do
        REXML::XPath.match(@document, "count()")
      end
    end

    def test_callback_exception_is_not_wrapped
      error = RuntimeError.new("callback failed")
      functions = {"urn:tenant-a" => {"score" => ->(_items) { raise error }}}

      raised = assert_raise(RuntimeError) do
        REXML::XPath.match(@document, "a:score(//item)", NAMESPACES, {}, functions:)
      end
      assert_same(error, raised)
    end

    def test_inner_function_table_does_not_override_outer_table
      outer = {"urn:tenant-a" => {"score" => OuterScore.new(@document)}}

      assert_equal([102],
                   REXML::XPath.match(@document, "a:score(//item)", NAMESPACES, {}, functions: outer))
    end

    def test_inner_function_table_can_add_without_overriding_outer_table
      document = @document
      call_count = 0
      score = ->(items) do
        call_count += 1
        if call_count == 1
          REXML::XPath.match(document,
                             "a:extra(//item)",
                             NAMESPACES,
                             {},
                             functions: {
                               "urn:tenant-a" => {
                                 "score" => ->(_items) { -1 },
                                 "extra" => ->(items) { items.size }
                               }
                             })
        end
        items.size
      end

      functions = {"urn:tenant-a" => {"score" => score}}
      assert_equal([3],
                   REXML::XPath.match(@document, "a:score(//item)", NAMESPACES, {}, functions:))
    end

    def test_inner_function_table_does_not_override_builtins
      outer_function = proc { |items|
        REXML::XPath.match(@document,
                            "count($items)",
                            nil,
                            {"items" => items},
                            functions: {"urn:tenant-a" => {"score" => ->(_items) { -1 }}})
        items.size
      }
      functions = {"urn:tenant-a" => {"score" => outer_function}}

      assert_equal([3],
                   REXML::XPath.match(@document, "a:score(//item)", NAMESPACES, {}, functions:))
    end

    def test_extension_function_does_not_override_builtin
      functions = {"" => {"count" => ->(_items) { -1 }}}

      assert_equal([3], REXML::XPath.match(@document, "count(//item)", nil, {}, functions:))
    end

    def test_functions_must_be_a_hash
      assert_raise(RuntimeError) do
        REXML::XPath.match(@document, "a:score()", NAMESPACES, {}, functions: [])
      end
    end
  end

  class OuterScore
    def initialize(document)
      @document = document
      @depth = 0
    end

    def call(items)
      @depth += 1
      if @depth == 1
        nested = REXML::XPath.match(@document,
                                    "a:score(/)",
                                    TestXPathExtensionFunctions::NAMESPACES,
                                    {},
                                    functions: {
                                      "urn:tenant-a" => {
                                        "score" => ->(_items) { -1 }
                                      }
                                    }).first
        @depth -= 1
        items.size + nested
      else
        @depth -= 1
        99
      end
    end
  end
end
