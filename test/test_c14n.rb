# frozen_string_literal: false

require_relative "helper"

module REXMLTests
  class TestC14n < Test::Unit::TestCase
    include Helper::Fixture
    include REXML

    OFFICIAL_XML = <<-XML
<?xml version="1.0"?>
<?xml-stylesheet   href="doc.xsl"
   type="text/xsl"   ?>
<!DOCTYPE doc SYSTEM "doc.dtd">
<doc>Hello, world!<!-- Comment 1 --><chapter  xmlns="http://www.ietf.org" xmlns:w3c="http://www.w3.org"><w3c:b></w3c:b>
   <w3c:a xmlns:w3c="http://www.w3.org/C14N" w3c:foo="yes" href="http://www.w3.org/" a='2&#xA;  3' b="I'm">
      <b xmlns:x="x">xxxxxxxxx<y/></b>
   </w3c:a>
   <c w3c:foo="yes" href="http://www.w3.org/">don't</c>
</chapter>
<?pi
   doo?><![CDATA[Not included.]]></doc>
    XML

    OFFICIAL_WITHOUT_COMMENTS =
      %Q{<?xml-stylesheet href="doc.xsl"\n   type="text/xsl"?>\n} +
      %Q{<doc>Hello, world!<chapter xmlns="http://www.ietf.org" xmlns:w3c="http://www.w3.org">} +
      %Q{<w3c:b></w3c:b>\n   } +
      %Q{<w3c:a xmlns:w3c="http://www.w3.org/C14N" a="2&#xA;  3" b="I'm" } +
      %Q{href="http://www.w3.org/" w3c:foo="yes">} +
      %Q{\n      <b xmlns:x="x">xxxxxxxxx<y></y></b>\n   </w3c:a>\n   } +
      %Q{<c href="http://www.w3.org/" w3c:foo="yes">don't</c>} +
      %Q{\n</chapter>\n<?pi\n   doo?>Not included.</doc>}

    OFFICIAL_WITH_COMMENTS =
      OFFICIAL_WITHOUT_COMMENTS.sub("Hello, world!", "Hello, world!<!-- Comment 1 -->")

    def test_official_vector_without_comments
      document = Document.new(OFFICIAL_XML)
      assert_equal_bytes(OFFICIAL_WITHOUT_COMMENTS, document.canonicalize)
    end

    def test_official_vector_with_comments
      document = Document.new(OFFICIAL_XML)
      assert_equal_bytes(OFFICIAL_WITH_COMMENTS, document.canonicalize(true))
    end

    def test_exclusive_uses_only_rendered_namespaces
      xml = <<~XML
        <root xmlns:unused="http://example.com/unused"
              xmlns:a="http://example.com/a">
          <a:child a:name="value" plain="value"/>
        </root>
      XML
      document = Document.new(xml)
      expected =
        %Q{<root>\n  <a:child xmlns:a="http://example.com/a" } +
        %Q{plain="value" a:name="value"></a:child>\n</root>}

      assert_equal_bytes(expected, document.root.canonicalize_exclusive)
    end

    def test_unrelated_prefix_declaration_does_not_change_exclusive_output
      one_xml = %q{<root xmlns:a="http://example.com/a"><a:child>text</a:child></root>}
      two_xml = %q{<root xmlns:a="http://example.com/a" xmlns:z="http://example.com/unused"><a:child>text</a:child></root>}
      one = Document.new(one_xml).root.canonicalize_exclusive
      two = Document.new(two_xml).root.canonicalize_exclusive

      assert_equal(one, two)
      assert_equal_bytes(%q{<root><a:child xmlns:a="http://example.com/a">text</a:child></root>}, one)
    end

    def test_subtree_inherits_namespace
      document = Document.new(<<~XML)
        <root xmlns:a="http://example.com/a" xmlns:b="http://example.com/b">
          <a:child a:x="1" b:y="2"/>
        </root>
      XML
      child = XPath.first(document, "//a:child")

      inclusive = %q{<a:child xmlns:a="http://example.com/a" xmlns:b="http://example.com/b" } +
                  %q{a:x="1" b:y="2"></a:child>}
      exclusive = %q{<a:child xmlns:a="http://example.com/a" xmlns:b="http://example.com/b" } +
                  %q{a:x="1" b:y="2"></a:child>}

      assert_equal_bytes(inclusive, child.canonicalize)
      assert_equal_bytes(exclusive, child.canonicalize_exclusive)
    end

    def test_subtree_includes_inherited_xml_attributes
      document = Document.new(<<~XML)
        <root xml:lang="en" xml:space="preserve" xml:base="outer/">
          <middle xml:base="inner/">
          <outer><child>text</child></outer>
          </middle>
        </root>
      XML
      child = XPath.first(document, "//child")
      expected = %q{<child xml:base="outer/inner/" xml:lang="en" xml:space="preserve">text</child>}

      assert_equal_bytes(expected, child.canonicalize)
      assert_equal_bytes(%q{<child>text</child>}, child.canonicalize_exclusive)
    end

    def test_default_namespace_undeclaration
      document = Document.new(<<~XML)
        <root xmlns="http://example.com/default">
          <child xmlns=""><grandchild/></child>
        </root>
      XML
      child = XPath.first(document, "//child")
      expected = %q{<child xmlns=""><grandchild></grandchild></child>}

      assert_equal_bytes(expected, child.canonicalize)
      assert_equal_bytes(expected, child.canonicalize_exclusive)
    end

    def test_default_namespace_is_used_inside_prefixed_subtree
      document = Document.new(%q{<root xmlns="http://example.com/default">} +
                             %q{<a:child xmlns:a="http://example.com/a"><inner>text</inner></a:child></root>})
      child = XPath.first(document, "//a:child")
      expected = %q{<a:child xmlns:a="http://example.com/a">} +
                 %q{<inner xmlns="http://example.com/default">text</inner></a:child>}

      assert_equal_bytes(expected, child.canonicalize)
      assert_equal_bytes(expected, child.canonicalize_exclusive)
    end

    def test_selected_node_set_writes_wrapper_elements
      document = Document.new(%q{<root xmlns="http://example.com/default" xml:lang="en"><outer xmlns:a="http://example.com/a"><a:child><included>keep</included></a:child></outer><ignored>skip</ignored></root>})
      nodes = XPath.match(document, "//outer | //included")
      expected =
        %Q{<outer xmlns="http://example.com/default" xmlns:a="http://example.com/a" xml:lang="en">} +
        %Q{<a:child><included>keep</included></a:child></outer>}

      assert_equal_bytes(expected, document.canonicalize(false, nodes))
    end

    def test_exclusive_inclusive_prefix_list
      document = Document.new(<<~XML)
        <root xmlns:n1="http://www.w3.org">
          <n1:outer xmlns:n2="ftp://www.ietf.org">
            <n2:child n1:attr="x"/>
          </n1:outer>
        </root>
      XML
      child = XPath.first(document, "//n2:child")
      expected =
        %q{<n2:child xmlns:n1="http://www.w3.org" xmlns:n2="ftp://www.ietf.org" } +
        %q{n1:attr="x"></n2:child>}

      assert_equal_bytes(expected, child.canonicalize_exclusive(false, nil, %w[n1 n2]))
    end

    def test_comments_in_selected_node_set
      document = Document.new(<<~XML)
        <root><outer>keep<!--selected--><child/></outer><!--ignored--></root>
      XML
      nodes = XPath.match(document, "//outer | //comment()")

      assert_equal_bytes(%q{<outer>keep<child></child></outer>},
                         document.canonicalize(false, nodes))
      assert_equal_bytes(%q{<outer>keep<!--selected--><child></child></outer><!--ignored-->},
                         document.canonicalize(true, nodes))
    end

    def test_whitespace_outside_document_element_is_ignored
      document = Document.new("\n<!--comment-->\n<?pi data?>\n<root/>")

      assert_equal_bytes(%Q{<?pi data?>\n<root></root>}, document.canonicalize)
      assert_equal_bytes(%Q{<!--comment-->\n<?pi data?>\n<root></root>},
                         document.canonicalize(true))
    end

    def test_processing_instruction_content_normalization
      document = Document.new(%Q{<r><?pi data \n  ?><child/></r>})
      instruction = XPath.first(document, "//processing-instruction('pi')")

      assert_equal_bytes(%Q{<?pi data\n?>},
                         C14n::Canonical11.new.canonicalize(instruction))
    end

    def test_result_is_utf8_binary_and_dom_is_unchanged
      xml = +"<root \xC3\xA9=\"\xC3\xA9\">\xC3\xA9</root>"
      xml.force_encoding(::Encoding::BINARY)
      document = Document.new(xml)
      before = document.to_s

      result = document.canonicalize

      assert_equal(::Encoding::BINARY, result.encoding)
      assert_equal_bytes(%Q{<root \xC3\xA9="\xC3\xA9">\xC3\xA9</root>}, result)
      assert_equal(before, document.to_s)
    end

    def test_attribute_and_text_nodes
      document = Document.new(%q{<root a="1"><child>text</child></root>})
      nodes = XPath.match(document, "//@a | //text()")

      assert_equal_bytes(%q{a="1"text}, document.canonicalize(false, nodes))
    end

    def test_cdata_and_namespace_declaration_nodes
      document = Document.new(%q{<root xmlns:a="http://example.com/a"><child><![CDATA[a<b>&c]]></child></root>})
      cdata = XPath.first(document, "//child/text()")
      namespace_node = XPath.first(document, "//@xmlns:a")

      assert_equal_bytes(%q{a&lt;b&gt;&amp;c},
                         document.canonicalize(false, [cdata]))
      assert_equal_bytes(%q{xmlns:a="http://example.com/a"},
                         document.canonicalize(false, [namespace_node]))
    end

    def test_c14n_class_accepts_xpath
      document = Document.new(<<~XML)
        <root xmlns:a="http://example.com/a"><a:child/></root>
      XML
      canonicalizer = C14n::Canonical11.new

      assert_equal_bytes(%q{<a:child xmlns:a="http://example.com/a"></a:child>},
                         canonicalizer.canonicalize(document, nil, "//a:child"))
    end

    private
    def assert_equal_bytes(expected, actual)
      expected = expected.b
      assert_equal(expected.force_encoding(::Encoding::BINARY), actual)
    end
  end
end
