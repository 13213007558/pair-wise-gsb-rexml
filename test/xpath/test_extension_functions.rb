# frozen_string_literal: false

require "test/unit"
require "rexml/document"
require "rexml/xpath"

module REXMLTests
  class TestXPathExtensionFunctions < Test::Unit::TestCase
    include REXML

    NAMESPACE_URI = "https://example.com/xpath-extensions"

    def setup
      @document = Document.new(<<~XML)
        <root xmlns:ext="#{NAMESPACE_URI}">
          <item>2</item>
          <item>5</item>
          <item>7</item>
          <marker/>
        </root>
      XML
      @namespaces = {"ext" => NAMESPACE_URI}
    end

    def test_tenant_functions_are_resolved_by_namespace_uri
      tenant_a = {NAMESPACE_URI => {"score" => ->(nodes) { Functions.number(nodes) * 2 }}}
      tenant_b = {NAMESPACE_URI => {"score" => ->(nodes) { Functions.number(nodes) + 10 }}}

      assert_equal([4],
                   XPath.match(@document,
                               "ext:score(//item[1])",
                               @namespaces,
                               {},
                               functions: tenant_a))
      assert_equal([12],
                   XPath.match(@document,
                               "ext:score(//item[1])",
                               @namespaces,
                               {},
                               functions: tenant_b))
    end

    def test_function_receives_node_set
      received = nil
      functions = {
        NAMESPACE_URI => {
          "score" => lambda do |nodes|
            received = nodes
            5
          end
        }
      }

      XPath.match(@document,
                  "ext:score(//item)",
                  @namespaces,
                  {},
                  functions: functions)

      assert_equal(3, received.size)
      assert_equal(%w[2 5 7], received.map { |node| node.text.strip })
    end

    def test_results_are_converted_to_xpath_values
      target = @document.root.elements["item[2]"]
      functions = {
        "" => {
          "node_result" => -> { target },
          "nodeset_result" => -> { [target] },
          "number_result" => -> { 42 },
          "boolean_result" => -> { true },
          "symbol_result" => -> { :answer },
          "nil_result" => -> { nil }
        }
      }
      options = {functions: functions}

      assert_equal([target], XPath.match(@document, "nodeset_result()", nil, {}, **options))
      assert_equal([target], XPath.match(@document, "node_result()", nil, {}, **options))
      assert_equal([42], XPath.match(@document, "number_result()", nil, {}, **options))
      assert_equal([true], XPath.match(@document, "boolean_result()", nil, {}, **options))
      assert_equal(["answer"], XPath.match(@document, "symbol_result()", nil, {}, **options))
      assert_equal([""], XPath.match(@document, "nil_result()", nil, {}, **options))
    end

    def test_unknown_arity_and_callback_errors_are_distinct
      error = assert_raise(XPath::UnknownFunctionError) do
        XPath.match(@document, "ext:missing()", @namespaces)
      end
      assert_kind_of(ArgumentError, error)
      assert_match(Regexp.new(Regexp.escape("{#{NAMESPACE_URI}}missing")), error.message)

      arity_functions = {NAMESPACE_URI => {"score" => ->(required, other) { required + other }}}
      arity_error = assert_raise(XPath::FunctionArityError) do
        XPath.match(@document,
                    "ext:score(//item)",
                    @namespaces,
                    {},
                    functions: arity_functions)
      end
      assert_kind_of(ArgumentError, arity_error)
      assert_equal("wrong number of XPath function arguments (given 1, expected 2)",
                   arity_error.message)

      proc_functions = {NAMESPACE_URI => {"score" => Proc.new { |required, other| required + other }}}
      proc_error = assert_raise(XPath::FunctionArityError) do
        XPath.match(@document,
                    "ext:score(//item)",
                    @namespaces,
                    {},
                    functions: proc_functions)
      end
      assert_equal("wrong number of XPath function arguments (given 1, expected 2)",
                   proc_error.message)

      callback_error = RuntimeError.new("boom")
      callback_functions = {NAMESPACE_URI => {"score" => -> { raise callback_error }}}
      raised = assert_raise(RuntimeError) do
        XPath.match(@document,
                    "ext:score()",
                    @namespaces,
                    {},
                    functions: callback_functions)
      end
      assert_same(callback_error, raised)
    end

    def test_callback_argument_error_is_not_reported_as_arity
      functions = {
        NAMESPACE_URI => {
          "score" => ->(_nodes) { raise ArgumentError, "callback failed" }
        }
      }

      error = assert_raise(ArgumentError) do
        XPath.match(@document,
                    "ext:score(//item)",
                    @namespaces,
                    {},
                    functions: functions)
      end
      assert_instance_of(ArgumentError, error)
      assert_equal("callback failed", error.message)
    end

    def test_nested_evaluation_cannot_override_outer_functions
      calls = []
      inner_functions = {
        NAMESPACE_URI => {
          "inner" => lambda do |nodes|
            calls << :inner
            XPath.match(nodes.first,
                        "ext:score()",
                        @namespaces,
                        {},
                        functions: inner_functions)
            1
          end,
          "score" => ->(_nodes) { calls << :inner_score; 999 }
        }
      }
      outer_functions = {
        NAMESPACE_URI => {
          "score" => lambda do |nodes = nil|
            calls << :outer_score
            next 1 if nodes.nil?
            next 1 if nodes.first.name == "marker"

            XPath.match(@document,
                        "ext:inner(//marker)",
                        @namespaces,
                        {},
                        functions: inner_functions)
            7
          end
        }
      }

      result = XPath.match(@document,
                           "ext:score(/root)",
                           @namespaces,
                           {},
                           functions: outer_functions)

      assert_equal([7], result)
      assert_equal([:outer_score, :inner, :outer_score], calls)
    end

    def test_extension_functions_do_not_override_builtins
      functions = {
        "" => {"true" => -> { false }},
        NAMESPACE_URI => {"true" => -> { false }}
      }

      assert_equal([true],
                   XPath.match(@document, "true()", nil, {}, functions: functions))
      assert_equal([false],
                   XPath.match(@document,
                               "ext:true()",
                               @namespaces,
                               {},
                               functions: functions))
    end

    def test_registration_does_not_change_global_functions
      functions = {NAMESPACE_URI => {"score" => -> { 1 }}}

      assert_not_respond_to(Functions, :score)
      XPath.match(@document, "ext:score()", @namespaces, {}, functions: functions)
      assert_not_respond_to(Functions, :score)
      assert_raise(ArgumentError) do
        Functions.call("score", args: [])
      end
    end
  end
end
