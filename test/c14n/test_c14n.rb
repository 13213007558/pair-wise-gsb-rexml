# frozen_string_literal: false

require_relative "../helper"

module REXMLTests
  class TestC14n < Test::Unit::TestCase
    include REXML

    def test_canonical_xml_1_1_official_shape
      document = Document.new(<<-XML)
<?xml version="1.0"?>
<?pi data?>
<!DOCTYPE root [
  <!ATTLIST root default CDATA "dtd">
  <!ATTLIST n0:item id CDATA "item">
]>
<root xmlns:n0="http://example.com/ns" xml:lang="en" explicit="yes"><n0:item n0:b="B" b="b" a="a"><!--comment--><![CDATA[x<y&z]]>&#xD;</n0:item></root>
XML
      expected = "<?pi data?><root xmlns:n0=\"http://example.com/ns\" default=\"dtd\" explicit=\"yes\" xml:lang=\"en\"><n0:item a=\"a\" b=\"b\" id=\"item\" n0:b=\"B\">x&lt;y&amp;z&#xD;</n0:item></root>"
      actual = document.canonicalize

      assert_equal(expected, actual)
      assert_equal(::Encoding::UTF_8, actual.encoding)
      assert_equal(expected.b, actual.b)
    end

    def test_comments
      without_comments = Document.new("<root><!--comment--></root>")
      with_comments = Document.new("<root><!--comment--></root>")

      assert_equal("<root></root>",
                   without_comments.canonicalize(REXML::C14n::XML_C14N_1_1, false))
      assert_equal("<root><!--comment--></root>",
                   with_comments.canonicalize(REXML::C14n::XML_C14N_1_1, true))
      assert_equal("<root><!--comment--></root>",
                   with_comments.canonicalize(REXML::C14n::XML_C14N_EXCLUSIVE_1_0, true))
    end

    def test_exclusive_omits_unused_ancestor_prefix
      document = Document.new('<n0:root xmlns:n0="http://example.com/root" xmlns:n1="http://example.com/unused"><n0:child/></n0:root>')

      assert_equal('<n0:root xmlns:n0="http://example.com/root"><n0:child></n0:child></n0:root>',
                   document.canonicalize(REXML::C14n::XML_C14N_EXCLUSIVE_1_0))
    end

    def test_exclusive_is_independent_of_unrelated_prefixes
      first = Document.new('<p:root xmlns:p="http://example.com/ns"><p:child/></p:root>')
      second = Document.new('<q:root xmlns:q="http://example.com/ns"><q:child/></q:root>')

      assert_equal('<p:root xmlns:p="http://example.com/ns"><p:child></p:child></p:root>',
                   first.canonicalize(REXML::C14n::XML_C14N_EXCLUSIVE_1_0))
      assert_equal('<q:root xmlns:q="http://example.com/ns"><q:child></q:child></q:root>',
                   second.canonicalize(REXML::C14n::XML_C14N_EXCLUSIVE_1_0))
    end

    def test_selected_subtree_inherits_default_and_prefixed_namespaces
      document = Document.new('<root xmlns="http://example.com/default" xmlns:p="http://example.com/prefixed"><p:child><deep/></p:child></root>')
      child = XPath.first(document, "//*[local-name()='child']")
      deep = XPath.first(document, "//deep")

      assert_equal('<p:child xmlns:p="http://example.com/prefixed"><deep xmlns="http://example.com/default"></deep></p:child>',
                   child.canonicalize(REXML::C14n::XML_C14N_1_1))
      assert_equal('<deep xmlns="http://example.com/default"></deep>',
                   deep.canonicalize(REXML::C14n::XML_C14N_1_1))
      assert_equal("<deep></deep>",
                   deep.canonicalize(REXML::C14n::XML_C14N_EXCLUSIVE_1_0))
    end

    def test_default_namespace_undeclaration_on_selected_subtree
      document = Document.new('<root xmlns="http://example.com/ns"><child xmlns=""><deep/></child></root>')
      deep = XPath.first(document, "//deep")

      assert_equal('<deep xmlns=""></deep>',
                   deep.canonicalize(REXML::C14n::XML_C14N_1_1))
    end

    def test_inherited_xml_attributes
      document = Document.new('<root xml:lang="en" xml:space="preserve" xml:base="/a/"><child/></root>')
      child = XPath.first(document, "//child")

      assert_equal('<child xml:base="/a/" xml:lang="en" xml:space="preserve"></child>',
                   child.canonicalize(REXML::C14n::XML_C14N_1_1))
      assert_equal("<child></child>",
                   child.canonicalize(REXML::C14n::XML_C14N_1_0))
    end

    def test_exclusive_inclusive_prefix_list
      document = Document.new('<p:root xmlns:p="http://example.com/p" xmlns:i="http://example.com/i"><p:parent><i:item/></p:parent></p:root>')

      assert_equal('<p:root xmlns:i="http://example.com/i" xmlns:p="http://example.com/p"><p:parent><i:item></i:item></p:parent></p:root>',
                   document.canonicalize(REXML::C14n::XML_C14N_EXCLUSIVE_1_0, ["i"]))
    end

    def test_exclusive_inclusive_default_prefix_on_selected_subtree
      document = Document.new('<root xmlns="http://example.com/ns"><child><deep/></child></root>')
      child = XPath.first(document, "//child")

      assert_equal('<child xmlns="http://example.com/ns"><deep></deep></child>',
                   child.canonicalize(REXML::C14n::XML_C14N_EXCLUSIVE_1_0, ["#default"]))
    end

    def test_selected_node_set
      document = Document.new("<root><a>one</a><b>two</b><!--skip--></root>")
      nodes = XPath.match(document, "//a | //b")

      assert_equal("<a>one</a><b>two</b>",
                   document.canonicalize(REXML::C14n::XML_C14N_1_1,
                                        false,
                                        nil,
                                        nodes))
    end

    def test_mixed_element_and_processing_instruction_node_set
      document = Document.new("<root><a></a><?pi data?><b></b></root>")
      nodes = XPath.match(document, "//a | //b | //processing-instruction()")

      assert_equal("<root><a></a><?pi data?><b></b></root>",
                   document.canonicalize(REXML::C14n::XML_C14N_1_1,
                                        false,
                                        nil,
                                        nodes))
    end

    def test_namespace_axis_node
      document = Document.new('<root xmlns:p="http://example.com/p"><p:item/></root>')
      namespace_node = document.root.attributes.get_attribute("xmlns:p")

      assert_equal('<root xmlns:p="http://example.com/p"></root>',
                   document.canonicalize(REXML::C14n::XML_C14N_EXCLUSIVE_1_0,
                                         false,
                                         nil,
                                         [namespace_node]))
    end

    def test_namespace_axis_keeps_element_when_element_and_node_are_selected
      document = Document.new('<root xmlns:p="http://example.com/p"><p:item>text</p:item></root>')
      namespace_node = document.root.attributes.get_attribute("xmlns:p")

      assert_equal('<root xmlns:p="http://example.com/p"><p:item>text</p:item></root>',
                   document.canonicalize(REXML::C14n::XML_C14N_EXCLUSIVE_1_0,
                                         false,
                                         nil,
                                         [document.root, namespace_node]))
    end

    def test_newline_outside_document_root_is_omitted
      document = Document.new("\n<?pi data?>\n<root/>\n")

      assert_equal("<?pi data?><root></root>",
                   document.canonicalize(REXML::C14n::XML_C14N_1_1))
    end

    def test_canonicalization_does_not_modify_dom
      xml = "<root xmlns:p='http://example.com/ns'><p:child xml:lang='en'/></root>"
      document = Document.new(xml)
      child = XPath.first(document, "//p:child")

      child.canonicalize(REXML::C14n::XML_C14N_1_1)
      child.canonicalize(REXML::C14n::XML_C14N_EXCLUSIVE_1_0)

      assert_equal(xml, document.to_s)
    end

    def test_selected_attribute_and_text_do_not_mutate_dom
      document = Document.new('<root xmlns:p="http://example.com/p"><p:item a="x">text</p:item></root>')
      item = XPath.first(document, "//p:item")
      attribute = item.attributes.get_attribute("a")
      text = item.children.first
      original = document.to_s

      result = document.canonicalize(REXML::C14n::XML_C14N_1_1,
                                     false,
                                     nil,
                                     [attribute, text])

      assert_equal("<root xmlns:p='http://example.com/p'><p:item a='x'>text</p:item></root>",
                   original)
      assert_equal('<root xmlns:p="http://example.com/p"><p:item a="x">text</p:item></root>', result)
      assert_equal("<root xmlns:p='http://example.com/p'><p:item a='x'>text</p:item></root>",
                   document.to_s)
    end

    def test_attribute_order_is_canonical
      document = Document.new('<item xmlns:z="http://example.com/z" xmlns:a="http://example.com/a" z:z="z" a:a="a" plain="plain" z:a="za"/>')
      item = XPath.first(document, "//item")

      assert_equal('<item xmlns:a="http://example.com/a" xmlns:z="http://example.com/z" plain="plain" a:a="a" z:a="za" z:z="z"></item>',
                   item.canonicalize(REXML::C14n::XML_C14N_1_1))
    end
  end
end
