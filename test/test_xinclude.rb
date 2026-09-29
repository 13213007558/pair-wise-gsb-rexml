# frozen_string_literal: false

require_relative "helper"
require "rexml/xinclude"

class XIncludeTest < Test::Unit::TestCase
  XI = REXML::XInclude::NAMESPACE

  def parse(source)
    REXML::Document.new(source)
  end

  def process(source, resources, **options)
    resolver = ->(uri) { resources[uri] }
    REXML::XInclude.process(parse(source), resolver: resolver, **options)
  end

  def xinclude(source, resources, **options)
    process(<<-XML, resources, **options)
<doc xmlns:xi="#{XI}">#{source}</doc>
    XML
  end

  def test_include_xml_replaces_include_element
    document = xinclude('<xi:include href="item.xml"/>',
                        {"item.xml" => "<item>Hi</item>"})
    item = document.root.elements[1]
    assert_equal("item", item.name)
    assert_equal("Hi", item.text)
  end

  def test_include_xml_is_the_default_parse
    document = xinclude('<xi:include href="item.xml"/>',
                        {"item.xml" => "<item/>"})
    assert_equal("item", document.root.elements[1].name)
  end

  def test_include_text_inserts_escaped_text
    document = xinclude('<xi:include href="note.txt" parse="text"/>',
                        {"note.txt" => "5 < 6 & 7"})
    assert_equal("5 < 6 & 7", document.root.text)
    assert_include(document.root.to_s, "5 &lt; 6 &amp; 7")
  end

  def test_include_text_transcodes_to_utf_8
    latin1 = "caf\u00e9".encode(Encoding::ISO_8859_1)
    document = xinclude('<xi:include href="note.txt" parse="text"/>',
                        {"note.txt" => latin1})
    text = document.root.text
    assert_equal("caf\u00e9", text)
    assert_equal(Encoding::UTF_8, text.encoding)
  end

  def test_include_text_treats_binary_as_utf_8
    binary = "caf\u00e9".b
    document = xinclude('<xi:include href="note.txt" parse="text"/>',
                        {"note.txt" => binary})
    assert_equal("caf\u00e9", document.root.text)
  end

  def test_fallback_used_when_resource_missing
    document = xinclude(<<-XML, {})
<xi:include href="missing.xml">
  <xi:fallback><default>fallback</default></xi:fallback>
</xi:include>
    XML
    default = document.root.elements[1]
    assert_equal("default", default.name)
    assert_equal("fallback", default.text)
  end

  def test_fallback_used_when_resolver_raises
    resolver = ->(uri) { raise Errno::ENOENT, uri }
    document = REXML::XInclude.process(
      parse(<<-XML),
<doc xmlns:xi="#{XI}">
  <xi:include href="missing.xml"><xi:fallback><d/></xi:fallback></xi:include>
</doc>
      XML
      resolver: resolver)
    assert_equal("d", document.root.elements[1].name)
  end

  def test_missing_resource_without_fallback_raises
    error = assert_raise(REXML::XInclude::ResourceError) do
      xinclude('<xi:include href="missing.xml"/>', {})
    end
    assert_include(error.message, "missing.xml")
  end

  def test_fallback_failure_propagates
    assert_raise(REXML::XInclude::ResourceError) do
      xinclude(<<-XML, {})
<xi:include href="missing.xml">
  <xi:fallback><xi:include href="also-missing.xml"/></xi:fallback>
</xi:include>
      XML
    end
  end

  def test_unparsable_xml_uses_fallback
    document = xinclude(<<-XML, {"broken.xml" => "<not-closed>"})
<xi:include href="broken.xml">
  <xi:fallback><default/></xi:fallback>
</xi:include>
    XML
    assert_equal("default", document.root.elements[1].name)
  end

  def test_relative_href_resolves_against_xml_base
    seen = []
    resolver = ->(uri) { seen << uri; "<item/>" }
    REXML::XInclude.process(
      parse(<<-XML),
<doc xmlns:xi="#{XI}" xml:base="http://example.com/dir/">
  <xi:include href="sub/item.xml"/>
</doc>
      XML
      resolver: resolver)
    assert_equal(["http://example.com/dir/sub/item.xml"], seen)
  end

  def test_relative_href_resolves_against_base_option
    seen = []
    resolver = ->(uri) { seen << uri; "<item/>" }
    REXML::XInclude.process(
      parse(%(<doc xmlns:xi="#{XI}"><xi:include href="item.xml"/></doc>)),
      resolver: resolver,
      base: "http://example.com/dir/page.xml")
    assert_equal(["http://example.com/dir/item.xml"], seen)
  end

  def test_nested_include_uses_resource_base
    resources = {
      "http://example.com/a.xml" =>
        %(<outer xmlns:xi="#{XI}"><xi:include href="b.xml"/></outer>),
      "http://example.com/b.xml" => "<inner>deep</inner>",
    }
    document = process(<<-XML, resources)
<doc xmlns:xi="#{XI}" xml:base="http://example.com/">
  <xi:include href="a.xml"/>
</doc>
    XML
    outer = document.root.elements[1]
    inner = outer.elements[1]
    assert_equal("outer", outer.name)
    assert_equal("inner", inner.name)
    assert_equal("deep", inner.text)
    assert_equal("http://example.com/b.xml", inner.attributes["xml:base"])
  end

  def test_xml_base_fixup_added_when_resource_base_differs
    document = process(<<-XML, {"http://example.com/dir/item.xml" => "<item/>"})
<doc xmlns:xi="#{XI}" xml:base="http://example.com/dir/">
  <xi:include href="item.xml"/>
</doc>
    XML
    item = document.root.elements[1]
    assert_equal("http://example.com/dir/item.xml",
                 item.attributes["xml:base"])
  end

  def test_xml_base_fixup_keeps_existing_xml_base
    document = xinclude('<xi:include href="item.xml"/>',
                        {"item.xml" => %(<item xml:base="sub/"/>)})
    assert_equal("sub/", document.root.elements[1].attributes["xml:base"])
  end

  def test_xml_lang_inherited_by_included_element
    document = process(<<-XML, {"item.xml" => "<item/>"})
<doc xmlns:xi="#{XI}" xml:lang="en"><xi:include href="item.xml"/></doc>
    XML
    assert_equal("en", document.root.elements[1].attributes["xml:lang"])
  end

  def test_xml_lang_not_inherited_when_already_set
    document = process(<<-XML, {"item.xml" => %(<item xml:lang="fr"/>)})
<doc xmlns:xi="#{XI}" xml:lang="en"><xi:include href="item.xml"/></doc>
    XML
    assert_equal("fr", document.root.elements[1].attributes["xml:lang"])
  end

  def test_loop_detection
    resources = {
      "a.xml" => %(<xi:include href="a.xml" xmlns:xi="#{XI}"/>),
    }
    assert_raise(REXML::XInclude::InclusionLoopError) do
      xinclude('<xi:include href="a.xml"/>', resources)
    end
  end

  def test_loop_detection_with_differently_spelled_uri
    resources = {
      "dir/a.xml" => %(<xi:include href="./sub/../a.xml" xmlns:xi="#{XI}"/>),
    }
    error = assert_raise(REXML::XInclude::InclusionLoopError) do
      xinclude('<xi:include href="dir/./a.xml"/>', resources)
    end
    assert_include(error.message, "dir/a.xml")
  end

  def test_same_resource_included_twice_as_siblings_is_allowed
    document = xinclude(
      '<xi:include href="item.xml"/><xi:include href="item.xml"/>',
      {"item.xml" => "<item/>"})
    assert_equal(["item", "item"],
                 document.root.elements.map {|element| element.name })
  end

  def test_xpointer_element_child_sequence
    document = xinclude(
      '<xi:include href="list.xml" xpointer="element(/1/2)"/>',
      {"list.xml" => "<root><a>one</a><b>two</b></root>"})
    item = document.root.elements[1]
    assert_equal("b", item.name)
    assert_equal("two", item.text)
  end

  def test_xpointer_element_id
    document = xinclude(
      '<xi:include href="list.xml" xpointer="element(target)"/>',
      {"list.xml" => %(<root><item xml:id="target">hit</item></root>)})
    item = document.root.elements[1]
    assert_equal("item", item.name)
    assert_equal("hit", item.text)
  end

  def test_xpointer_element_id_with_child_sequence
    document = xinclude(
      '<xi:include href="list.xml" xpointer="element(target/1)"/>',
      {"list.xml" => %(<root><item xml:id="target"><leaf/></item></root>)})
    assert_equal("leaf", document.root.elements[1].name)
  end

  def test_xpointer_without_match_uses_fallback
    document = xinclude(<<-XML,
<xi:include href="list.xml" xpointer="element(missing)">
  <xi:fallback><default/></xi:fallback>
</xi:include>
    XML
                        {"list.xml" => "<root/>"})
    assert_equal("default", document.root.elements[1].name)
  end

  def test_xpointer_unsupported_scheme
    assert_raise(REXML::XInclude::UnsupportedSchemeError) do
      xinclude('<xi:include href="list.xml" xpointer="xpointer(/root)"/>',
               {"list.xml" => "<root/>"})
    end
  end

  def test_xpointer_unsupported_scheme_with_other_scheme
    error = assert_raise(REXML::XInclude::UnsupportedSchemeError) do
      xinclude(
        '<xi:include href="list.xml" ' \
        'xpointer="xmlns(p=http://example.com) element(/1)"/>',
        {"list.xml" => "<root/>"})
    end
    assert_include(error.message, "xmlns")
  end

  def test_include_root_node_of_resource_document
    document = xinclude(
      '<xi:include href="doc.xml"/>',
      {"doc.xml" => %(<?xml version="1.0"?><root><child/></root>)})
    root = document.root.elements[1]
    assert_equal("root", root.name)
    assert_equal("child", root.elements[1].name)
  end

  def test_parent_document_namespaces_are_preserved
    document = process(<<-XML,
<doc xmlns="http://example.com/main"
     xmlns:p="http://example.com/p"
     xmlns:xi="#{XI}">
  <p:head/>
  <xi:include href="frag.xml"/>
</doc>
    XML
                       {"frag.xml" =>
                        %(<frag xmlns="http://example.com/frag"><kid/></frag>)})
    root = document.root
    assert_equal("http://example.com/main", root.namespace)
    assert_equal("http://example.com/p", root.namespaces["p"])
    assert_equal("http://example.com/p", root.elements[1].namespace)
    frag = root.elements[2]
    assert_equal("frag", frag.name)
    assert_equal("http://example.com/frag", frag.namespace)
    assert_equal("http://example.com/frag", frag.elements[1].namespace)
    found = REXML::XPath.first(document, "/main:doc/frag:frag/frag:kid",
                               "main" => "http://example.com/main",
                               "frag" => "http://example.com/frag")
    assert_not_nil(found)
  end

  def test_copy_mode_keeps_original_and_ownership_separate
    original = parse(<<-XML)
<doc xmlns:xi="#{XI}"><keep/><xi:include href="item.xml"/></doc>
    XML
    result = REXML::XInclude.process(
      original,
      resolver: ->(uri) { "<item/>" })
    assert_not_same(original, result)
    assert_not_nil(REXML::XPath.first(original, "/doc/xi:include", "xi" => XI))
    assert_nil(REXML::XPath.first(result, "/doc/xi:include", "xi" => XI))
    assert_equal(["keep", "item"],
                 result.root.elements.map {|element| element.name })
    assert_all_owned_by(original, original)
    assert_all_owned_by(result, result)
  end

  def test_in_place_mode_expands_the_given_document
    document = parse(<<-XML)
<doc xmlns:xi="#{XI}"><xi:include href="item.xml"/></doc>
    XML
    result = REXML::XInclude.process(
      document,
      resolver: ->(uri) { "<item/>" },
      in_place: true)
    assert_same(document, result)
    assert_equal("item", document.root.elements[1].name)
    assert_all_owned_by(document, document)
  end

  def test_same_document_include_via_xpointer
    document = xinclude(
      '<item xml:id="x">data</item><xi:include xpointer="element(x)"/>',
      {})
    names = document.root.elements.map {|element| element.name }
    assert_equal(["item", "item"], names)
    assert_not_same(document.root.elements[1], document.root.elements[2])
    assert_all_owned_by(document, document)
  end

  def test_invalid_parse_value_raises
    assert_raise(REXML::XInclude::InvalidIncludeError) do
      xinclude('<xi:include href="a.txt" parse="binary"/>', {})
    end
  end

  def test_fallback_outside_include_raises
    assert_raise(REXML::XInclude::InvalidIncludeError) do
      xinclude("<xi:fallback><d/></xi:fallback>", {})
    end
  end

  private

  def assert_all_owned_by(node, document)
    assert_same(document, node.root_node)
    node.each_element {|element| assert_all_owned_by(element, document) }
  end
end
