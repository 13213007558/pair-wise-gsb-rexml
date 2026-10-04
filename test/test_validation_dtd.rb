# frozen_string_literal: false
require "test/unit"
require "rexml/document"
require "rexml/validation/dtd"

module REXMLTests
  class TestValidationDTD < Test::Unit::TestCase
    def test_sequence_choice_and_repetitions
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root (a, b?, (c|d)+, e*)>
        <!ELEMENT a EMPTY>
        <!ELEMENT b EMPTY>
        <!ELEMENT c EMPTY>
        <!ELEMENT d EMPTY>
        <!ELEMENT e EMPTY>
      DTD
        <root><a/><d/><d/><e/></root>
      XML
      assert_valid(document)
    end

    def test_top_level_group_repetition
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root ((a, b)*, c?)>
        <!ELEMENT a EMPTY>
        <!ELEMENT b EMPTY>
        <!ELEMENT c EMPTY>
      DTD
        <root><a/><b/><a/><b/></root>
      XML
      assert_valid(document)
    end

    def test_sequence_order_error_is_associated_with_element_and_declaration
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root (a, b)>
        <!ELEMENT a EMPTY>
        <!ELEMENT b EMPTY>
      DTD
        <root><b/><a/></root>
      XML
      error = only_error(document)
      assert_equal(:invalid_content, error.code)
      assert_same(document.root, error.node)
      assert_equal("(a, b)", error.declaration.content)
    end

    def test_root_name_mismatch
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root EMPTY>
      DTD
        <other>text</other>
      XML
      assert_equal(%i[root_mismatch], document.validate.map(&:code))
    end

    def test_empty_and_any
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root ANY>
        <!ELEMENT empty EMPTY>
        <!ELEMENT any ANY>
        <!ELEMENT leaf EMPTY>
      DTD
        <root><empty><any>text<leaf/></any></empty></root>
      XML
      error = only_error(document)
      assert_equal(:invalid_content, error.code)
      assert_equal("empty", error.node.expanded_name)
    end

    def test_any_reports_undeclared_child_not_content_model_error
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root ANY>
        <!ELEMENT child EMPTY>
      DTD
        <root>text<child/><undeclared/></root>
      XML
      assert_equal(%i[undeclared_element], document.validate.map(&:code))
    end

    def test_mixed_content
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root (#PCDATA|a|b)*>
        <!ELEMENT a EMPTY>
        <!ELEMENT b EMPTY>
      DTD
        <root>before<a/>between<b/>after</root>
      XML
      assert_valid(document)

      invalid = parse(<<~DTD, <<~XML)
        <!ELEMENT root (#PCDATA|a)*>
        <!ELEMENT a EMPTY>
      DTD
        <root><a/><b/></root>
      XML
      assert_equal([:invalid_content],
                   invalid.validate.select { |error| error.node == invalid.root }.map(&:code))
    end

    def test_required_fixed_and_enumerated_attributes
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root EMPTY>
        <!ATTLIST root
          required ID #REQUIRED
          fixed CDATA #FIXED "yes"
          choice (one|two) "one">
      DTD
        <root required="id" fixed="no" choice="three"/>
      XML
      assert_equal(%i[fixed_attribute invalid_attribute],
                   document.validate.map(&:code).sort)
    end

    def test_token_and_notation_attribute_types
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root EMPTY>
        <!ATTLIST root
          token NMTOKEN #IMPLIED
          tokens NMTOKENS #IMPLIED
          notation NOTATION (one|two) #IMPLIED>
      DTD
        <root token="one" tokens="one two" notation="three"/>
      XML
      errors = document.validate
      assert_equal([:invalid_attribute], errors.map(&:code))
      assert_equal("notation", errors.first.node.expanded_name)
    end

    def test_forward_id_reference
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root (source, target)>
        <!ELEMENT target EMPTY>
        <!ELEMENT source EMPTY>
        <!ATTLIST target id ID #REQUIRED>
        <!ATTLIST source ref IDREF #REQUIRED>
      DTD
        <root><source ref="forward"/><target id="forward"/></root>
      XML
      assert_valid(document)
    end

    def test_duplicate_id
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root EMPTY>
        <!ATTLIST root first ID #IMPLIED>
        <!ATTLIST root second ID #IMPLIED>
      DTD
        <root first="same" second="same"/>
      XML
      error = document.validate.find { |candidate| candidate.code == :duplicate_id }
      assert_not_nil(error)
      assert_equal("second", error.node.expanded_name)
      assert_equal("second", error.declaration.attribute_definitions.last.name)
      assert_equal("root", error.declaration.element_name)
    end

    def test_dangling_idref
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root EMPTY>
        <!ATTLIST root refs IDREFS #REQUIRED>
      DTD
        <root refs="missing also-missing"/>
      XML
      errors = document.validate.select { |error| error.code == :dangling_idref }
      references = errors.map { |error| error.message[/"(.+?)"/, 1] }
      assert_equal(%w[missing also-missing], references)
      assert_equal(["refs", "refs"], errors.map { |error| error.node.expanded_name })
    end

    def test_default_attributes_are_separate_from_validation
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root EMPTY>
        <!ATTLIST root
          optional ID #IMPLIED
          default CDATA "value"
          fixed CDATA #FIXED "fixed">
      DTD
        <root/>
      XML
      assert_valid(document)
      assert_equal(false, document.root.attributes.include?("default"))
      assert_equal(false, document.root.attributes.include?("fixed"))

      document.apply_default_attributes
      assert_equal("value", document.root.attributes["default"])
      assert_equal("fixed", document.root.attributes["fixed"])
    end

    def test_default_entity_references_are_expanded_for_validation
      document = parse(<<~DTD, <<~XML)
        <!ENTITY id-value "identifier">
        <!ELEMENT root EMPTY>
        <!ATTLIST root
          id ID "&id-value;"
          ref IDREF "&id-value;">
      DTD
        <root/>
      XML
      assert_valid(document)

      document.apply_default_attributes
      assert_equal("identifier", document.root.attributes["id"])
      assert_equal("identifier", document.root.attributes["ref"])
    end

    def test_external_subset_is_not_loaded_or_assumed
      document = REXML::Document.new(<<~XML)
        <!DOCTYPE root SYSTEM "urn:x-rexml:do-not-fetch" [
          <!ELEMENT root EMPTY>
        ]>
        <root external="x"/>
      XML
      assert_valid(document)
    end

    def test_validate_bang_surfaces_node_declaration_and_all_errors
      document = parse(<<~DTD, <<~XML)
        <!ELEMENT root EMPTY>
        <!ATTLIST root ref IDREF #REQUIRED>
      DTD
        <root ref="missing" unexpected="x">text</root>
      XML
      exception = assert_raise(REXML::Validation::ValidationException) do
        document.validate!
      end
      assert_kind_of(REXML::Validation::DTD::Error, exception.errors.first)
      assert_same(document.root, exception.node)
      assert_equal(:invalid_content, exception.code)
    end

    private

    def parse(internal_subset, body)
      REXML::Document.new("<!DOCTYPE root [#{internal_subset}]>#{body}")
    end

    def assert_valid(document)
      assert_equal([], document.validate.map(&:message))
    end

    def only_error(document)
      errors = document.validate
      assert_equal(1, errors.length, errors.map(&:message))
      errors.first
    end
  end
end
