# frozen_string_literal: false

require_relative "helper"
require "rexml/xinclude"

module REXMLTests
  class TestXInclude < Test::Unit::TestCase
    XI = "http://www.w3.org/2001/XInclude"

    def make_processor(resources, base_uri: nil)
      REXML::XInclude.new(->(uri) { resources[uri] }, base_uri: base_uri)
    end

    def parse(source)
      REXML::Document.new(source)
    end

    def xi_includes(element)
      element.elements.to_a.select {|child| child.name == "include" }
    end

    def test_include_xml_replaces_include_element
      doc = parse(%{<root xmlns:xi="#{XI}"><xi:include href="child.xml"/></root>})
      processor = make_processor({"child.xml" => "<child><item/></child>"})
      assert_same(doc, processor.process(doc))
      assert_empty(xi_includes(doc.root))
      assert_equal("<child><item/></child>", doc.root.elements["child"].to_s)
    end

    def test_include_root_node_becomes_document_root
      doc = parse(%{<xi:include xmlns:xi="#{XI}" href="doc.xml"/>})
      make_processor({"doc.xml" => "<real-root>text</real-root>"}).process(doc)
      assert_equal("real-root", doc.root.name)
      assert_equal("text", doc.root.text)
    end

    def test_include_text
      doc = parse(%{<root xmlns:xi="#{XI}"><xi:include href="a.txt" parse="text"/></root>})
      make_processor({"a.txt" => "1 < 2 & 3"}).process(doc)
      assert_equal("1 < 2 & 3", doc.root.text)
      assert_include(doc.to_s, "1 &lt; 2 &amp; 3")
    end

    def test_include_text_default_utf8
      doc = parse(%{<root xmlns:xi="#{XI}"><xi:include href="u.txt" parse="text"/></root>})
      make_processor({"u.txt" => "héllo"}).process(doc)
      assert_equal("héllo", doc.root.text)
    end

    def test_include_text_with_encoding
      doc = parse(%{<root xmlns:xi="#{XI}">} +
                  %{<xi:include href="latin.txt" parse="text" encoding="ISO-8859-1"/>} +
                  %{</root>})
      content = "caf\xE9".dup.force_encoding(Encoding::BINARY)
      make_processor({"latin.txt" => content}).process(doc)
      assert_equal("café", doc.root.text)
      assert_equal(Encoding::UTF_8, doc.root.text.encoding)
    end

    def test_include_text_invalid_encoding_is_resource_error
      doc = parse(%{<root xmlns:xi="#{XI}">} +
                  %{<xi:include href="bad.txt" parse="text" encoding="UTF-8"/>} +
                  %{</root>})
      content = "\xFF\xFE".dup.force_encoding(Encoding::BINARY)
      processor = make_processor({"bad.txt" => content})
      assert_raise(REXML::XInclude::ResourceError) { processor.process(doc) }
    end

    def test_fallback_used_when_resource_missing
      doc = parse(%{<root xmlns:xi="#{XI}">} +
                  %{<xi:include href="missing.xml">} +
                  %{<xi:fallback><fallback-content/></xi:fallback>} +
                  %{</xi:include></root>})
      make_processor({}).process(doc)
      assert_equal("<fallback-content/>", doc.root.elements[1].to_s)
    end

    def test_fallback_used_when_xml_unparseable
      doc = parse(%{<root xmlns:xi="#{XI}">} +
                  %{<xi:include href="broken.xml">} +
                  %{<xi:fallback>oops</xi:fallback>} +
                  %{</xi:include></root>})
      make_processor({"broken.xml" => "<not-closed>"}).process(doc)
      assert_equal("oops", doc.root.text)
    end

    def test_fallback_content_includes_are_expanded
      doc = parse(%{<root xmlns:xi="#{XI}">} +
                  %{<xi:include href="missing.xml">} +
                  %{<xi:fallback><xi:include href="real.xml"/></xi:fallback>} +
                  %{</xi:include></root>})
      make_processor({"real.xml" => "<real/>"}).process(doc)
      assert_equal("<real/>", doc.root.elements[1].to_s)
    end

    def test_fallback_failure_propagates
      doc = parse(%{<root xmlns:xi="#{XI}">} +
                  %{<xi:include href="missing1.xml">} +
                  %{<xi:fallback><xi:include href="missing2.xml"/></xi:fallback>} +
                  %{</xi:include></root>})
      processor = make_processor({})
      error = assert_raise(REXML::XInclude::ResourceError) { processor.process(doc) }
      assert_include(error.message, "missing2.xml")
    end

    def test_missing_resource_without_fallback_raises
      doc = parse(%{<root xmlns:xi="#{XI}"><xi:include href="missing.xml"/></root>})
      processor = make_processor({})
      assert_raise(REXML::XInclude::ResourceError) { processor.process(doc) }
    end

    def test_relative_href_resolved_against_base_uri
      doc = parse(%{<root xmlns:xi="#{XI}"><xi:include href="sub/child.xml"/></root>})
      seen = []
      processor = REXML::XInclude.new(
        ->(uri) { seen << uri; "<child/>" },
        base_uri: "http://example.com/dir/main.xml")
      processor.process(doc)
      assert_equal(["http://example.com/dir/sub/child.xml"], seen)
    end

    def test_xml_base_affects_resolution
      doc = parse(%{<root xmlns:xi="#{XI}" xml:base="http://example.com/a/">} +
                  %{<section xml:base="b/">} +
                  %{<xi:include href="c.xml"/>} +
                  %{</section></root>})
      seen = []
      REXML::XInclude.new(->(uri) { seen << uri; "<c/>" }).process(doc)
      assert_equal(["http://example.com/a/b/c.xml"], seen)
    end

    def test_nested_includes_resolve_against_included_resource
      resources = {
        "http://example.com/a/one.xml" =>
          %{<one xmlns:xi="#{XI}"><xi:include href="two.xml"/></one>},
        "http://example.com/a/two.xml" => "<two/>",
      }
      doc = parse(%{<root xmlns:xi="#{XI}"><xi:include href="one.xml"/></root>})
      make_processor(resources, base_uri: "http://example.com/a/main.xml").process(doc)
      one = doc.root.elements["one"]
      assert_equal("http://example.com/a/one.xml", one.attributes["xml:base"])
      two = one.elements["two"]
      assert_equal("http://example.com/a/two.xml", two.attributes["xml:base"])
    end

    def test_xml_base_fixup_added_when_bases_differ
      doc = parse(%{<root xmlns:xi="#{XI}"><xi:include href="sub/child.xml"/></root>})
      make_processor({"http://example.com/sub/child.xml" => "<child/>"},
                     base_uri: "http://example.com/main.xml").process(doc)
      child = doc.root.elements["child"]
      assert_equal("http://example.com/sub/child.xml", child.attributes["xml:base"])
    end

    def test_xml_base_fixup_not_added_when_base_matches
      doc = parse(%{<root xmlns:xi="#{XI}"><xi:include href="child.xml"/></root>})
      make_processor({"child.xml" => "<child/>"}).process(doc)
      assert_nil(doc.root.elements["child"].attributes["xml:base"])
    end

    def test_xml_base_fixup_not_added_when_present
      doc = parse(%{<root xmlns:xi="#{XI}"><xi:include href="sub/child.xml"/></root>})
      resource = %q{<child xml:base="http://other.example.com/x/"/>}
      make_processor({"http://example.com/sub/child.xml" => resource},
                     base_uri: "http://example.com/main.xml").process(doc)
      child = doc.root.elements["child"]
      assert_equal("http://other.example.com/x/", child.attributes["xml:base"])
    end

    def test_xml_lang_inherited
      doc = parse(%{<root xmlns:xi="#{XI}" xml:lang="en">} +
                  %{<xi:include href="a.xml"/><xi:include href="b.xml"/></root>})
      resources = {"a.xml" => "<a/>", "b.xml" => %q{<b xml:lang="ja"/>}}
      make_processor(resources).process(doc)
      assert_equal("en", doc.root.elements["a"].attributes["xml:lang"])
      assert_equal("ja", doc.root.elements["b"].attributes["xml:lang"])
    end

    def test_circular_include_detected_with_normalized_uris
      resources = {
        "http://example.com/a/one.xml" =>
          %{<one xmlns:xi="#{XI}"><xi:include href="../a/./one.xml"/></one>},
      }
      doc = parse(%{<root xmlns:xi="#{XI}"><xi:include href="a/one.xml"/></root>})
      processor = make_processor(resources, base_uri: "http://example.com/main.xml")
      assert_raise(REXML::XInclude::CircularIncludeError) { processor.process(doc) }
    end

    def test_circular_include_detected_across_resources
      resources = {
        "http://example.com/a.xml" =>
          %{<a xmlns:xi="#{XI}"><xi:include href="b.xml"/></a>},
        "http://example.com/b.xml" =>
          %{<b xmlns:xi="#{XI}"><xi:include href="x/../a.xml"/></b>},
      }
      doc = parse(%{<root xmlns:xi="#{XI}"><xi:include href="a.xml"/></root>})
      processor = make_processor(resources, base_uri: "http://example.com/main.xml")
      assert_raise(REXML::XInclude::CircularIncludeError) { processor.process(doc) }
    end

    def test_self_inclusion_detected
      resources = {"http://example.com/main.xml" => "<x/>"}
      doc = parse(%{<root xmlns:xi="#{XI}"><xi:include href="main.xml"/></root>})
      processor = make_processor(resources, base_uri: "http://example.com/main.xml")
      assert_raise(REXML::XInclude::CircularIncludeError) { processor.process(doc) }
    end

    def test_diamond_inclusion_is_not_circular
      resources = {
        "http://example.com/d.xml" => "<d/>",
        "http://example.com/b.xml" =>
          %{<b xmlns:xi="#{XI}"><xi:include href="d.xml"/></b>},
        "http://example.com/c.xml" =>
          %{<c xmlns:xi="#{XI}"><xi:include href="d.xml"/></c>},
      }
      doc = parse(%{<root xmlns:xi="#{XI}">} +
                  %{<xi:include href="b.xml"/><xi:include href="c.xml"/></root>})
      make_processor(resources, base_uri: "http://example.com/main.xml").process(doc)
      assert_equal("d", doc.root.elements["b"].elements[1].name)
      assert_equal("d", doc.root.elements["c"].elements[1].name)
      assert_equal("http://example.com/d.xml",
                   doc.root.elements["b"].elements[1].attributes["xml:base"])
    end

    def test_element_xpointer_by_id
      doc = parse(%{<root xmlns:xi="#{XI}">} +
                  %{<xi:include href="doc.xml" xpointer="element(target)"/></root>})
      resource = %{<doc><a xml:id="target"><b>hit</b></a><a xml:id="other"/></doc>}
      make_processor({"doc.xml" => resource}).process(doc)
      assert_equal(1, doc.root.elements.size)
      assert_equal("<b>hit</b>", doc.root.elements["a"].elements[1].to_s)
    end

    def test_element_xpointer_by_child_sequence
      doc = parse(%{<root xmlns:xi="#{XI}">} +
                  %{<xi:include href="doc.xml" xpointer="element(/2/1)"/></root>})
      resource = %{<doc><a/><b><c>deep</c></b></doc>}
      make_processor({"doc.xml" => resource}).process(doc)
      assert_equal("<c>deep</c>", doc.root.elements[1].to_s)
    end

    def test_element_xpointer_by_id_and_sequence
      doc = parse(%{<root xmlns:xi="#{XI}">} +
                  %{<xi:include href="doc.xml" xpointer="element(top/2)"/></root>})
      resource = %{<doc><wrap xml:id="top"><x>1</x><x>2</x></wrap></doc>}
      make_processor({"doc.xml" => resource}).process(doc)
      assert_equal("<x>2</x>", doc.root.elements[1].to_s)
    end

    def test_element_xpointer_without_match_uses_fallback
      doc = parse(%{<root xmlns:xi="#{XI}">} +
                  %{<xi:include href="doc.xml" xpointer="element(nope)">} +
                  %{<xi:fallback><fb/></xi:fallback>} +
                  %{</xi:include></root>})
      make_processor({"doc.xml" => "<doc/>"}).process(doc)
      assert_equal("<fb/>", doc.root.elements[1].to_s)
    end

    def test_unsupported_xpointer_scheme_is_fatal
      doc = parse(%{<root xmlns:xi="#{XI}">} +
                  %{<xi:include href="doc.xml" xpointer="xpointer(/doc/a)">} +
                  %{<xi:fallback><fb/></xi:fallback>} +
                  %{</xi:include></root>})
      processor = make_processor({"doc.xml" => "<doc><a/></doc>"})
      error = assert_raise(REXML::XInclude::UnsupportedSchemeError) do
        processor.process(doc)
      end
      assert_include(error.message, "xpointer")
    end

    def test_same_document_xpointer_include
      doc = parse(%{<root xmlns:xi="#{XI}">} +
                  %{<a xml:id="src"><b>hi</b></a>} +
                  %{<xi:include xpointer="element(src)"/>} +
                  %{</root>})
      make_processor({}).process(doc)
      assert_equal(2, doc.root.elements.to_a.size)
      assert_equal("<b>hi</b>", doc.root.elements["a[2]"].elements[1].to_s)
    end

    def test_parent_document_namespaces_preserved
      doc = parse(%{<root xmlns:p="urn:parent" xmlns:xi="#{XI}">} +
                  %{<p:wrapper><xi:include href="child.xml"/></p:wrapper>} +
                  %{</root>})
      resource = %{<child xmlns:c="urn:child"><c:item/></child>}
      make_processor({"child.xml" => resource}).process(doc)
      assert_equal("urn:parent", doc.root.namespace("p"))
      child = doc.root.elements["p:wrapper"].elements["child"]
      assert_equal("urn:child", child.namespace("c"))
      assert_equal("urn:parent", child.namespace("p"))
      assert_equal("urn:child", child.elements["c:item"].namespace)
    end

    def test_process_expands_in_place
      doc = parse(%{<root xmlns:xi="#{XI}"><xi:include href="c.xml"/></root>})
      original_root = doc.root
      result = make_processor({"c.xml" => "<c/>"}).process(doc)
      assert_same(doc, result)
      assert_same(original_root, doc.root)
      assert_equal("<c/>", doc.root.elements[1].to_s)
    end

    def test_process_copy_returns_expanded_copy
      doc = parse(%{<root xmlns:xi="#{XI}"><keep/><xi:include href="c.xml"/></root>})
      copy = make_processor({"c.xml" => "<c/>"}).process_copy(doc)
      assert_not_same(doc, copy)
      assert_not_same(doc.root, copy.root)
      assert_not_same(doc.root.elements["keep"], copy.root.elements["keep"])
      assert_equal("<c/>", copy.root.elements["c"].to_s)
      assert_nil(doc.root.elements["c"])
      assert_equal(1, xi_includes(doc.root).size)
      assert_empty(xi_includes(copy.root))
      assert_same(copy, copy.root.elements["c"].document)
    end

    def test_invalid_parse_attribute_raises
      doc = parse(%{<root xmlns:xi="#{XI}">} +
                  %{<xi:include href="a.xml" parse="dom"/></root>})
      processor = make_processor({"a.xml" => "<a/>"})
      assert_raise(REXML::XInclude::Error) { processor.process(doc) }
    end

    def test_resolver_exception_becomes_resource_error
      doc = parse(%{<root xmlns:xi="#{XI}"><xi:include href="a.xml"/></root>})
      processor = REXML::XInclude.new(->(uri) { raise "boom" })
      assert_raise(REXML::XInclude::ResourceError) { processor.process(doc) }
    end
  end
end
