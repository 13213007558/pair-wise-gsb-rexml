# frozen_string_literal: false

require_relative "helper"
require "rexml/dtd/dtd"
require "rexml/document"

module REXMLTests
  class DTDContentModelTest < Test::Unit::TestCase
    ContentModel = REXML::DTD::ContentModel

    def parse(spec)
      ContentModel.parse(spec)
    end

    def test_sequence
      model = parse("(a, b, c)")
      assert_equal(:element, model.kind)
      assert_equal(true, model.validate(%w[a b c]))
      assert_equal(false, model.valid?(%w[a c b]))
    end

    def test_sequence_mismatch_reports_position_actual_and_expected
      model = parse("(a, b, c)")
      error = assert_raise(ContentModel::MismatchError) do
        model.validate(%w[a c])
      end
      assert_equal(1, error.position)
      assert_equal("c", error.actual)
      assert_equal(["b"], error.expected)
    end

    def test_premature_end_reports_expected_elements
      model = parse("(a, b)")
      error = assert_raise(ContentModel::MismatchError) do
        model.validate(%w[a])
      end
      assert_equal(1, error.position)
      assert_nil(error.actual)
      assert_equal(["b"], error.expected)
    end

    def test_choice
      model = parse("(a | b | c)")
      assert_equal(true, model.validate(%w[b]))
      assert_equal(false, model.valid?(%w[a b]))
    end

    def test_repetition
      model = parse("(a, b*, c+, d?)")
      assert_equal(true, model.validate(%w[a c]))
      assert_equal(true, model.validate(%w[a b b c c c d]))
      assert_equal(false, model.valid?(%w[a d]))
      assert_equal(false, model.valid?(%w[a c d d]))
    end

    def test_nested_repetition
      model = parse("((a|b)*, (c, (d|e)+)?)")
      assert_equal(true, model.validate([]))
      assert_equal(true, model.validate(%w[a b a]))
      assert_equal(true, model.validate(%w[a c d e d]))
      assert_equal(false, model.valid?(%w[c]))
      assert_equal(false, model.valid?(%w[a c d b]))
    end

    def test_nullable_branches
      model = parse("(a?, (b|c)?, d)")
      assert_equal(true, model.validate(%w[d]))
      assert_equal(true, model.validate(%w[a d]))
      assert_equal(true, model.validate(%w[b d]))
      assert_equal(true, model.validate(%w[a c d]))
      error = assert_raise(ContentModel::MismatchError) do
        model.validate(%w[a a])
      end
      assert_equal(1, error.position)
      assert_equal("a", error.actual)
      assert_equal(%w[b c d], error.expected)
    end

    def test_same_name_in_different_positions_is_deterministic
      model = parse("(a, b, a)")
      assert_equal(true, model.validate(%w[a b a]))
      error = assert_raise(ContentModel::MismatchError) do
        model.validate(%w[a b b])
      end
      assert_equal(2, error.position)
      assert_equal("b", error.actual)
      assert_equal(["a"], error.expected)
    end

    def test_ambiguous_choice_is_rejected_before_validating
      error = assert_raise(ContentModel::AmbiguityError) do
        parse("((a, b) | (a, c))")
      end
      assert_equal("a", error.element_name)
    end

    def test_ambiguous_same_name_choice_is_rejected
      assert_raise(ContentModel::AmbiguityError) do
        parse("(a | a)")
      end
    end

    def test_ambiguous_nullable_repetition_is_rejected
      assert_raise(ContentModel::AmbiguityError) do
        parse("(a*, a)")
      end
    end

    def test_empty
      model = parse("EMPTY")
      assert_equal(:empty, model.kind)
      assert_equal(true, model.validate([]))
      error = assert_raise(ContentModel::MismatchError) do
        model.validate(%w[a])
      end
      assert_equal(0, error.position)
      assert_equal("a", error.actual)
      assert_equal([], error.expected)
    end

    def test_any
      model = parse("ANY")
      assert_equal(:any, model.kind)
      assert_equal(true, model.validate([]))
      assert_equal(true, model.validate(%w[anything at all]))
    end

    def test_mixed_text_only
      model = parse("(#PCDATA)")
      assert_equal(:mixed, model.kind)
      assert_equal([], model.names)
      assert_equal(true, model.validate([]))
      assert_equal(false, model.valid?(%w[em]))
    end

    def test_mixed_with_elements
      model = parse("(#PCDATA | em | strong)*")
      assert_equal(:mixed, model.kind)
      assert_equal(%w[em strong], model.names)
      assert_equal(true, model.validate([]))
      assert_equal(true, model.validate(%w[em em strong em]))
      error = assert_raise(ContentModel::MismatchError) do
        model.validate(%w[em b])
      end
      assert_equal(1, error.position)
      assert_equal("b", error.actual)
      assert_equal(%w[em strong], error.expected)
    end

    def test_mixed_requires_star_when_elements_present
      assert_raise(ContentModel::SyntaxError) do
        parse("(#PCDATA | em)")
      end
    end

    def test_mixed_text_only_forbids_quantifier
      assert_raise(ContentModel::SyntaxError) do
        parse("(#PCDATA)*")
      end
    end

    def test_mixed_forbids_duplicate_names
      assert_raise(ContentModel::SyntaxError) do
        parse("(#PCDATA | em | em)*")
      end
    end

    def test_syntax_errors
      assert_raise(ContentModel::SyntaxError) { parse("(a, b") }
      assert_raise(ContentModel::SyntaxError) { parse("a, b") }
      assert_raise(ContentModel::SyntaxError) { parse("()") }
      assert_raise(ContentModel::SyntaxError) { parse("(a | b, c)") }
      assert_raise(ContentModel::SyntaxError) { parse("(a) extra") }
    end

    def test_streaming_validator
      validator = parse("(a, b*)").validator
      assert_equal(0, validator.position)
      assert_equal(["a"], validator.expected)
      assert_equal(false, validator.finished?)
      assert_equal(true, validator.consume("a"))
      assert_equal(true, validator.finished?)
      assert_equal(true, validator.consume("b"))
      assert_equal(false, validator.consume("c"))
      assert_equal(2, validator.position)
      assert_equal(["b"], validator.expected)
      validator.reset
      assert_equal(0, validator.position)
      assert_equal(false, validator.finished?)
    end

    def test_long_child_sequence_stays_linear
      model = parse("((a?)*, z)")
      children = ["a"] * 100_000 + ["z"]
      assert_equal(true, model.validate(children))
    end

    def test_long_child_sequence_mismatch_at_end
      model = parse("(item)*")
      children = ["item"] * 100_000 + ["bogus"]
      error = assert_raise(ContentModel::MismatchError) do
        model.validate(children)
      end
      assert_equal(100_000, error.position)
      assert_equal("bogus", error.actual)
      assert_equal(["item"], error.expected)
    end

    def test_dtd_parser_element_decl_entry
      dtd = REXML::DTD::Parser.parse("<!ELEMENT root (a, (b | c)*)>")
      decl = dtd.to_a.find { |child| child.kind_of?(REXML::DTD::ElementDecl) }
      assert_equal("root", decl.name)
      assert_equal(true, decl.content_model.validate(%w[a b c b]))
    end

    def test_doctype_element_decl_entry
      doc = REXML::Document.new(<<-XML)
<!DOCTYPE root [
<!ELEMENT root (a, b*)>
<!ELEMENT a EMPTY>
<!ELEMENT b (#PCDATA | em)*>
]>
<root><a/><b/><b/></root>
      XML
      models = {}
      doc.doctype.children.each do |child|
        next unless child.kind_of?(REXML::ElementDecl)
        models[child.name] = child.content_model
      end
      assert_equal(:element, models["root"].kind)
      assert_equal(:empty, models["a"].kind)
      assert_equal(:mixed, models["b"].kind)
      assert_equal(true, models["root"].validate(%w[a b b]))
      assert_equal(false, models["root"].valid?(%w[b a]))
      assert_equal(true, models["b"].validate(%w[em em]))
    end
  end
end
