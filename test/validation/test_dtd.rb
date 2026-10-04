# frozen_string_literal: false

require "test/unit"

require "rexml/document"

module REXMLTests
  class TestValidationDTD < Test::Unit::TestCase
    def test_sequence_choice_and_repetitions
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root (a, b?, (c | d)+, e*)>
        <!ELEMENT a EMPTY>
        <!ELEMENT b EMPTY>
        <!ELEMENT c EMPTY>
        <!ELEMENT d EMPTY>
        <!ELEMENT e EMPTY>
      DTD
        <root><a/><d/><e/><e/></root>
      XML

      assert_valid(document)
    end

    def test_sequence_error_is_related_to_element_and_declaration
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root (a, b)>
        <!ELEMENT a EMPTY>
        <!ELEMENT b EMPTY>
      DTD
        <root><b/><a/></root>
      XML

      error = only_error(document)
      assert_equal("Element \"root\" does not satisfy its content model",
                   error.message)
      assert_same(document.root, error.node)
      assert_same(document.doctype.element_declarations["root"],
                  error.declaration)
    end

    def test_nested_repeated_particle
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root ((a, b)?)*>
        <!ELEMENT a EMPTY>
        <!ELEMENT b EMPTY>
      DTD
        <root><a/><b/><a/><b/></root>
      XML

      assert_valid(document)
    end

    def test_empty_allows_comments_and_processing_instructions
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root EMPTY>
      DTD
        <root><!-- ok --><?pi ok?></root>
      XML

      assert_valid(document)
    end

    def test_empty_rejects_text
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root EMPTY>
      DTD
        <root> </root>
      XML

      assert_equal("Element \"root\" must be empty",
                   only_error(document).message)
    end

    def test_any_allows_character_data_and_declared_children
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root ANY>
        <!ELEMENT child (#PCDATA)>
      DTD
        <root>text<child>more</child></root>
      XML

      assert_valid(document)
    end

    def test_mixed_content_accepts_repeated_declared_children
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root (#PCDATA | child | other)*>
        <!ELEMENT child EMPTY>
        <!ELEMENT other EMPTY>
      DTD
        <root>a<child/>b<other/><child/></root>
      XML

      assert_valid(document)
    end

    def test_mixed_content_rejects_sequences
      parse_error = assert_raise(REXML::ParseException) do
        parse(<<~DTD, "<root/>")
          <!ELEMENT root (#PCDATA, child)*>
          <!ELEMENT child EMPTY>
        DTD
      end
      assert_match("Malformed element declaration", parse_error.message)
    end

    def test_mixed_content_without_repetition_must_be_text_only
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root (#PCDATA)>
        <!ELEMENT child EMPTY>
      DTD
        <root>text<child/></root>
      XML

      error = only_error(document)
      assert_equal("Element \"child\" is not allowed in mixed content",
                   error.message)
      assert_same(document.root.children.grep(REXML::Element).first,
                  error.node)
    end

    def test_element_only_content_rejects_non_whitespace_characters
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root (child)*>
        <!ELEMENT child EMPTY>
      DTD
        <root><child/>bad</root>
      XML

      assert_equal("Element \"root\" has character data in element-only content",
                   only_error(document).message)
    end

    def test_required_enumeration_fixed_and_implied_attributes
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root EMPTY>
        <!ATTLIST root
          required ID #REQUIRED
          choice (one | two) "one"
          fixed CDATA #FIXED "yes"
          optional CDATA #IMPLIED>
      DTD
        <root required="a" fixed="yes"/>
      XML

      assert_valid(document)
    end

    def test_attribute_errors_reference_node_and_declaration
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root EMPTY>
        <!ATTLIST root value (one | two) #REQUIRED>
      DTD
        <root value="three"/>
      XML

      error = only_error(document)
      assert_equal("Attribute \"value\" must be one of [\"one\", \"two\"]",
                   error.message)
      assert_same(document.root, error.node)
      assert_equal("value", error.attribute)
      assert_same(document.doctype.grep(REXML::AttlistDecl).first,
                  error.declaration)
    end

    def test_forward_id_reference_is_valid
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root (ref, target)>
        <!ELEMENT ref EMPTY>
        <!ELEMENT target EMPTY>
        <!ATTLIST ref link IDREF #REQUIRED>
        <!ATTLIST target id ID #REQUIRED>
      DTD
        <root><ref link="later"/><target id="later"/></root>
      XML

      assert_valid(document)
    end

    def test_duplicate_ids_and_dangling_idrefs_are_separate_errors
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root (item*, ref*)>
        <!ELEMENT item EMPTY>
        <!ELEMENT ref EMPTY>
        <!ATTLIST item id ID #REQUIRED>
        <!ATTLIST ref link IDREF #REQUIRED>
      DTD
        <root>
          <item id="same"/>
          <item id="same"/>
          <ref link="missing"/>
        </root>
      XML

      messages = document.dtd_validation_errors.map(&:message)
      assert_equal([
                     "Duplicate ID \"same\"",
                     "ID reference \"missing\" does not refer to an ID"
                   ],
                   messages)
      duplicate = document.dtd_validation_errors.first
      assert_same(document.root.children.grep(REXML::Element)[1],
                  duplicate.node)
      assert_equal("id", duplicate.attribute)
    end

    def test_idrefs_accepts_whitespace_separated_forward_references
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root (refs, target*)>
        <!ELEMENT refs EMPTY>
        <!ELEMENT target EMPTY>
        <!ATTLIST refs links IDREFS #REQUIRED>
        <!ATTLIST target id ID #REQUIRED>
      DTD
        <root><refs links="one two"/><target id="one"/><target id="two"/></root>
      XML

      assert_valid(document)
    end

    def test_notation_attribute_requires_declared_notation
      document = parse(<<~DTD, <<~XML)
        <!NOTATION gif SYSTEM "image/gif">
        <!ELEMENT root EMPTY>
        <!ATTLIST root type NOTATION (gif | text) #IMPLIED>
      DTD
        <root type="gif"/>
      XML

      assert_valid(document)
    end

    def test_defaults_are_not_added_during_validation
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root EMPTY>
        <!ATTLIST root value CDATA "default">
      DTD
        <root/>
      XML

      assert_valid(document)
      assert_equal([], document.root.attributes.to_a)
      assert_equal("default", document.root.attributes["value"])
    end

    def test_add_default_attributes_mutates_tree_and_skips_explicit_values
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root (child)*>
        <!ELEMENT child EMPTY>
        <!ATTLIST root root-value CDATA "root-default">
        <!ATTLIST child child-value CDATA "child-default">
        <!ATTLIST child explicit CDATA "declared-default">
      DTD
        <root><child explicit="given"/></root>
      XML

      returned = document.add_default_attributes
      assert_same(document, returned)
      assert_equal("root-default", document.root.attributes["root-value"])
      child = document.root.children.grep(REXML::Element).first
      assert_equal("child-default", child.attributes["child-value"])
      assert_equal("given", child.attributes["explicit"])
    end

    def test_doctype_can_apply_default_attributes_directly
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root EMPTY>
        <!ATTLIST root value CDATA "default">
      DTD
        <root/>
      XML

      returned = document.doctype.apply_default_attributes
      assert_same(document.doctype, returned)
      assert_equal("default", document.root.attributes["value"])
    end

    def test_invalid_default_is_a_declaration_error
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root EMPTY>
        <!ATTLIST root value ID "1bad">
      DTD
        <root/>
      XML

      error = only_error(document)
      assert_equal("Default attribute \"value\" must be an XML Name",
                   error.message)
      assert_nil(error.node)
      assert_equal("value", error.attribute)
    end

    def test_external_dtd_is_not_loaded_or_treated_as_complete
      document = REXML::Document.new(<<~XML)
        <!DOCTYPE root SYSTEM "urn:x-test:not-fetched" [
          <!ATTLIST root value CDATA "internal">
        ]>
        <root other="ok">text</root>
      XML

      assert_valid(document)
      assert_equal("internal", document.root.attributes["value"])
    end

    def test_validate_raises_first_validation_error
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root EMPTY>
      DTD
        <root>text</root>
      XML

      error = assert_raise(REXML::Validation::DTD::Error) do
        document.validate_dtd
      end
      assert_equal("Element \"root\" must be empty", error.message)
    end

    private

    def parse(internal_subset, xml)
      REXML::Document.new("<!DOCTYPE root [\n#{internal_subset}]>\n#{xml}")
    end

    def assert_valid(document)
      assert_equal([], document.dtd_validation_errors)
      assert_equal(true, document.validate_dtd)
    end

    def only_error(document)
      errors = document.dtd_validation_errors
      assert_equal(1, errors.size, errors.map(&:message))
      errors.first
    end
  end
end
