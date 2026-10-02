require "test/unit"
require "rexml/document"
require "rexml/formatters/c14n"

module REXMLTests
  class CanonicalXML11FormatterTest < Test::Unit::TestCase
    def format(node, include_comments = true)
      REXML::Formatters::CanonicalXML11.new(include_comments).write(node)
    end

    def test_document_omits_xml_declaration_and_uses_canonical_escaping
      document = REXML::Document.new(<<~XML)
        <?xml version="1.1" encoding="UTF-16"?>
        <root a="&lt;>&amp;&quot;&#x9;&#xA;&#xD;"><![CDATA[<&>]]></root>
      XML

      assert_equal(
        "<root a=\"&lt;>&amp;&quot;&#x9;&#xA;&#xD;\">&lt;&amp;&gt;</root>",
        format(document)
      )
      assert_equal(Encoding::UTF_8, format(document).encoding)
    end

    def test_attributes_are_sorted_by_namespace_uri_and_local_name
      xml = '<r xmlns:a="http://a" a:z="1" y="2" a:a="3"/>'
      document = REXML::Document.new(xml)

      assert_equal(
        '<r xmlns:a="http://a" y="2" a:a="3" a:z="1"></r>',
        format(document.root)
      )
    end

    def test_namespace_declarations_are_sorted_and_not_redundantly_repeated
      xml = '<r xmlns="http://default" xmlns:a="http://a">' \
            '<c xmlns:a="http://a"><a:x xmlns:b="http://b" b:y="1"/></c></r>'
      document = REXML::Document.new(xml)

      assert_equal(
        '<r xmlns="http://default" xmlns:a="http://a">' +
          '<c><a:x xmlns:b="http://b" b:y="1"></a:x></c></r>',
        format(document)
      )
    end

    def test_comments_are_optional_but_processing_instructions_remain
      document = REXML::Document.new('<r><!-- comment --><?pi data?></r>')

      assert_equal('<r><?pi data?></r>', format(document.root, false))
      assert_equal('<r><!-- comment --><?pi data?></r>', format(document.root, true))
    end

    def test_document_level_processing_instructions_are_kept
      document = REXML::Document.new('<?pi data?><r/>')

      assert_equal('<?pi data?><r></r>', document.canonicalize)
    end

    def test_comment_line_endings_are_normalized
      document = REXML::Document.new("<r><!--a\rb--></r>")

      assert_equal("<r><!--a\nb--></r>", format(document))
    end

    def test_subtree_inherits_namespaces
      document = REXML::Document.new(
        '<r xmlns="http://default" xmlns:a="http://a"><a:c a:x="1"/></r>'
      )
      child = document.root.first

      assert_equal(
        '<a:c xmlns="http://default" xmlns:a="http://a" a:x="1"></a:c>',
        format(child)
      )
    end

    def test_subtree_undeclares_unused_default_namespace
      document = REXML::Document.new(
        '<r xmlns="http://default"><c><a:x xmlns:a="http://a"/></c></r>'
      )

      assert_equal(
        '<c xmlns="http://default"><a:x xmlns:a="http://a"></a:x></c>',
        format(document.root.first)
      )
    end

    def test_subtree_without_default_namespace_does_not_synthesize_one
      document = REXML::Document.new(
        '<r xmlns:a="http://a"><a:c><a:b/></a:c></r>'
      )

      assert_equal('<a:b xmlns:a="http://a"></a:b>',
                   format(document.root.first.first))
    end

    def test_subtree_inherits_xml_lang_space_and_absolute_xml_base_but_not_xml_id
      document = REXML::Document.new(
        '<r xml:id="r" xml:lang="en" xml:space="preserve" ' +
        'xml:base="http://example.com/base/"><c xml:id="c" xml:base="child.xml"/></r>'
      )
      child = document.root.first

      assert_equal(
        '<c xml:base="http://example.com/base/child.xml" xml:id="c" xml:lang="en" xml:space="preserve"></c>',
        format(child)
      )
    end

    def test_relative_xml_base_is_resolved_from_absolute_ancestor_only
      document = REXML::Document.new(
        '<r xml:base="relative1/"><c xml:base="child.xml"><x xml:base="x"/></c></r>'
      )

      assert_equal(
        '<c xml:base="relative1/child.xml"><x xml:base="x"></x></c>',
        format(document.root.first)
      )
    end

    def test_xml_base_resolution_removes_dot_segments
      document = REXML::Document.new(
        '<r xml:base="http://example.com/a/b"><c xml:base="../c?x#f"/></r>'
      )

      assert_equal(
        '<c xml:base="http://example.com/c?x#f"></c>',
        format(document.root.first)
      )
    end

    def test_original_tree_is_not_modified
      xml = '<r xmlns:a="http://a" xml:lang="en"><a:c xml:base="child.xml"/></r>'
      document = REXML::Document.new(xml)
      child = document.root.first
      before = child.to_s

      format(child)

      assert_equal(before, child.to_s)
      assert_equal("<r xmlns:a='http://a' xml:lang='en'><a:c xml:base='child.xml'/></r>",
                   document.root.to_s)
    end

    def test_convenience_methods
      document = REXML::Document.new('<r xmlns:a="http://a"><a:c/></r>')

      assert_equal(format(document, false), document.canonicalize(nil, false))
      assert_equal(format(document.root.first, false), document.root.first.canonicalize(false))
    end
  end
end
