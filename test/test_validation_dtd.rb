# frozen_string_literal: false

require_relative "helper"
require "rexml/validation/dtd"

module REXMLTests
  class TestDTDValidation < Test::Unit::TestCase
    def test_sequence
      model = REXML::Validation::DTD.new("(a, b, c)")

      assert_nil(model.validate(%w[a b c]))

      error = model.validate(%w[a c])
      assert_equal(1, error.position)
      assert_equal("c", error.actual)
      assert_equal(["b"], error.expected)
    end

    def test_choice
      model = REXML::Validation::DTD.new("(a | b | c)")

      assert_nil(model.validate(["a"]))
      assert_nil(model.validate(["b"]))
      assert_equal(%w[a b c], model.validate(["d"]).expected)
    end

    def test_repetition_operators
      model = REXML::Validation::DTD.new("(a?, b+, c*)")

      assert_nil(model.validate(%w[b]))
      assert_nil(model.validate(%w[b c c]))
      assert_nil(model.validate(%w[a b b c]))

      error = model.validate(%w[c])
      assert_equal(0, error.position)
      assert_equal("c", error.actual)
      assert_equal(%w[a b], error.expected)
    end

    def test_nested_repetition_and_nullable_branches
      model = REXML::Validation::DTD.new("((a | b)?, (c, d?)+)")

      assert_nil(model.validate(%w[a c c d]))
      assert_nil(model.validate(%w[c d c]))
      assert_nil(model.validate(%w[b c d]))

      error = model.validate(%w[a b c])
      assert_equal(1, error.position)
      assert_equal("b", error.actual)
      assert_equal(["c"], error.expected)
    end

    def test_optional_sequence
      model = REXML::Validation::DTD.new("(a, b)?")

      assert_nil(model.validate([]))
      assert_nil(model.validate(%w[a b]))
      error = model.validate(["a"])
      assert_equal(1, error.position)
      assert_equal(["b"], error.expected)
    end

    def test_nullable_choice_in_sequence
      model = REXML::Validation::DTD.new("((a | b | c*), d)")

      assert_nil(model.validate(%w[a d]))
      assert_nil(model.validate(%w[c c d]))
      assert_nil(model.validate(["d"]))
      assert_equal(%w[c d], model.validate(%w[c b]).expected.sort)
    end

    def test_same_name_in_different_positions_is_allowed_when_context_differs
      model = REXML::Validation::DTD.new("(a, (a, b)?)")

      assert_nil(model.validate(["a"]))
      assert_nil(model.validate(%w[a a b]))
      assert(model.deterministic?)
    end

    def test_nullable_branch_with_same_start_name_is_ambiguous
      assert_raise(REXML::Validation::ValidationException) do
        REXML::Validation::DTD.new("(a?, a)")
      end
    end

    def test_choice_ambiguity_is_reported_before_instance_validation
      error = assert_raise(REXML::Validation::ValidationException) do
        REXML::Validation::DTD.new("(a | a)")
      end
      assert_match(/Non-deterministic/, error.message)
    end

    def test_nested_choice_ambiguity
      assert_raise(REXML::Validation::ValidationException) do
        REXML::Validation::DTD.new("((a, b) | (a, c))")
      end
    end

    def test_repeated_choice_ambiguity
      assert_raise(REXML::Validation::ValidationException) do
        REXML::Validation::DTD.new("(a | a)*")
      end
    end

    def test_empty
      model = REXML::Validation::DTD.new("<!ELEMENT root EMPTY>")

      assert_equal("root", model.element_name)
      assert_nil(model.validate([]))
      error = model.validate(["a"])
      assert_equal(0, error.position)
      assert_equal("a", error.actual)
      assert_equal([], error.expected)
    end

    def test_any
      model = REXML::Validation::DTD.new("ANY")

      assert_nil(model.validate(%w[anything nested]))
      assert_nil(model.validate([]))
      assert_equal(["*"], model.expected)
    end

    def test_text_only
      model = REXML::Validation::DTD.new("(#PCDATA)")

      assert_nil(model.validate([]))
      assert_nil(model.feed(:text))
      error = model.validate(["a"])
      assert_equal("a", error.actual)
      assert_equal([], error.expected)
    end

    def test_mixed_content
      model = REXML::Validation::DTD.new("(#PCDATA | a | b)*")

      assert_nil(model.validate([]))
      assert_nil(model.feed(:text))
      assert_nil(model.feed("a"))
      assert_nil(model.feed(:text))
      assert_nil(model.feed("b"))

      error = model.validate(["c"])
      assert_equal(0, error.position)
      assert_equal("c", error.actual)
      assert_equal(%w[a b], error.expected)
    end

    def test_duplicate_mixed_name
      assert_raise(REXML::Validation::ValidationException) do
        REXML::Validation::DTD.new("(#PCDATA | a | a)*")
      end
    end

    def test_element_declaration_object
      doc = REXML::Document.new(<<-XML)
<!DOCTYPE root [<!ELEMENT root (a, b)>]>
<root><a/><b/></root>
      XML
      declaration = doc.doctype.children.first
      model = REXML::Validation::DTD.new(declaration)

      assert_nil(model.validate(doc.root.children))
    end

    def test_dom_ignores_comments_processing_instructions_and_element_whitespace
      doc = REXML::Document.new(<<-XML)
<!DOCTYPE root [<!ELEMENT root (a, b)>]>
<root>
  <!-- comment --><?pi data?>
  <a/> <b/>
</root>
      XML
      model = REXML::Validation::DTD.new(doc.doctype.children.first)

      assert_nil(model.validate(doc.root.children))
    end

    def test_non_whitespace_text_is_rejected_in_element_content
      doc = REXML::Document.new("<root>text<a/></root>")
      model = REXML::Validation::DTD.new("(a)")

      error = model.validate(doc.root.children)
      assert_equal(:text, error.actual)
      assert_equal(0, error.position)
    end

    def test_streaming_position_reports_consumed_children
      model = REXML::Validation::DTD.new("(a, b, c)")

      assert_nil(model.feed("a"))
      error = model.feed("c")
      assert_equal(1, error.position)
      assert_equal(["b"], error.expected)
      assert_equal("c", error.actual)
    end

    def test_error_does_not_consume_a_child
      model = REXML::Validation::DTD.new("(a, b)")

      assert_nil(model.feed("a"))
      assert(model.feed("a"))
      assert_equal(1, model.position)
      assert_nil(model.feed("b"))
      assert_nil(model.finish)
    end

    def test_unexpected_end
      model = REXML::Validation::DTD.new("(a, b)")
      error = model.validate(["a"])

      assert_equal(1, error.position)
      assert_nil(error.actual)
      assert_equal(["b"], error.expected)
    end

    def test_linear_validation_with_long_child_sequence
      model = REXML::Validation::DTD.new("(a*, b)")
      counts = [1000, 5000, 20000]
      elapsed = counts.map do |count|
        children = Array.new(count, "a") << "b"
        starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        assert_nil(model.validate(children))
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - starting
      end

      ratios = elapsed.each_cons(2).map {|first, second| second / first}
      assert(ratios.all? {|ratio| ratio < 8})
    end
  end
end
