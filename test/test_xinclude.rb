# -*- coding: utf-8 -*-
# frozen_string_literal: false

require_relative "helper"

require "rexml/xinclude"
require "tmpdir"
require "fileutils"

module REXMLTests
  class XIncludeTest < Test::Unit::TestCase
    include Helper::Fixture

    XI = "http://www.w3.org/2001/XInclude".freeze

    def setup
      @tmpdir = Dir.mktmpdir("rexml-xinclude-test")
      @parent1 = File.join(@tmpdir, "parent1")
      @parent2 = File.join(@tmpdir, "parent2")
      @shared = File.join(@tmpdir, "shared")
      FileUtils.mkdir_p(@parent1)
      FileUtils.mkdir_p(@parent2)
      FileUtils.mkdir_p(@shared)
    end

    def teardown
      FileUtils.remove_entry_secure(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
    end

    def write(relative, content)
      path = File.join(@tmpdir, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, content)
      path
    end

   def file_uri(path)
      parser = defined?(URI::RFC2396_PARSER) ? URI::RFC2396_PARSER : URI::DEFAULT_PARSER
      "file://" + parser.escape(File.expand_path(path))
   end

    def process(xml, path: "main.xml", base: nil, resolver: nil, dir: @tmpdir)
      full_path = File.join(dir, path)
      document = REXML::Document.new(xml)
      REXML::XInclude.process(
        document,
        resolver: resolver,
        base_uri: base || file_uri(full_path))
      document
    end

    def wrap(content, attributes = "")
      %Q{<r xmlns:xi=\"#{XI}\" #{attributes}>#{content}</r>}
    end

    # -- basic include -------------------------------------------------

    def test_xml_include_replaces_element
      write("a.xml", "<a>hello</a>")
      doc = process(wrap(%{<xi:include href="a.xml"/>}))
      assert_equal("a", doc.root.elements[1].name)
      assert_equal("hello", doc.root.elements["a"].text)
    end

    def test_xml_include_via_document_method
      write("a.xml", "<a>hello</a>")
      doc = REXML::Document.new(wrap(%{<xi:include href="a.xml"/>}))
      returned = doc.xinclude(base_uri: file_uri(File.join(@tmpdir, "main.xml")))
      assert_same(doc, returned)
      assert_equal("hello", doc.root.elements["a"].text)
    end

    def test_include_with_xml_declaration
      write("a.xml", %Q{<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a>x</a>})
      doc = process(wrap(%{<xi:include href="a.xml"/>}))
      assert_equal("a", doc.root.elements[1].name)
      assert_nil(doc.root.children.find { |c| c.is_a?(REXML::XMLDecl) })
    end

    def test_include_preserves_document_level_comments
      write("a.xml", "<!-- top --><a/> <!-- after -->")
      doc = process(wrap(%{<xi:include href="a.xml"/>}))
      names = doc.root.children.collect(&:class)
      assert_include(names, REXML::Comment)
    end

    # -- nested includes and the headline relative path scenario ------

    def test_nested_include_resolves_relative_to_included_resource
      write("shared/shared.xml",
            %Q{<s xmlns:xi=\"#{XI}\"><xi:include href=\"nested.xml\"/></s>})
      write("shared/nested.xml", "<nested>deep</nested>")
      write("parent1/main.xml", wrap(%{<xi:include href=\"../shared/shared.xml\"/>}))
      write("parent2/main.xml", wrap(%{<xi:include href=\"../shared/shared.xml\"/>}))

      [@parent1, @parent2].each do |dir|
        doc = REXML::Document.new(File.read(File.join(dir, "main.xml")))
        REXML::XInclude.process(doc, base_uri: file_uri(File.join(dir, "main.xml")))
        nested = doc.root.elements["s/nested"]
        assert_not_nil(nested, "nested include must resolve in #{dir}")
        assert_equal("deep", nested.text)
        nested_base = nested.attribute("xml:base").value
        assert_equal(file_uri(File.join(@shared, "nested.xml")), nested_base)
      end
    end

    def test_nested_include_chain
      write("a.xml", %Q{<a xmlns:xi=\"#{XI}\"><xi:include href=\"b.xml\"/></a>})
      write("b.xml", %Q{<b xmlns:xi=\"#{XI}\"><xi:include href=\"c.xml\"/></b>})
      write("c.xml", "<c>leaf</c>")
      doc = process(wrap(%{<xi:include href=\"a.xml\"/>}))
      assert_equal("leaf", doc.root.elements["a/b/c"].text)
    end

    # -- base URI fixup -----------------------------------------------

    def test_base_fixup_adds_xml_base
      write("a.xml", "<a/>")
      doc = process(wrap(%{<xi:include href="a.xml"/>}))
      assert_equal(file_uri(File.join(@tmpdir, "a.xml")),
                   doc.root.elements["a"].attribute("xml:base").value)
    end

    def test_base_fixup_resolves_existing_relative_xml_base
      write("a.xml", %q{<a xml:base="sub/"/>})
      write("sub/b.xml", "<b/>")
      doc = process(wrap(%{<xi:include href=\"a.xml\"/>}))
      expected = file_uri(File.join(@tmpdir, "sub", "b.xml")).sub(%r{/b[.]xml$}, "/")
      assert_equal(expected, doc.root.elements["a"].attribute("xml:base").value)
    end

    def test_xml_base_attribute_on_include_redirects_resolution
      write("real.xml", "<real/>")
      write("sub/real.xml", "<real-from-sub/>")
      doc = process(wrap(%{<xi:include xml:base=\"sub/\" href=\"real.xml\"/>}))
      assert_not_nil(doc.root.elements["real-from-sub"])
    end

    # -- language fixup -----------------------------------------------

    def test_language_fixup_inherits_in_scope_language
      write("a.xml", "<a/>")
      doc = process(wrap(%{<xi:include href=\"a.xml\"/>}, %{xml:lang=\"fr\"}))
      assert_equal("fr", doc.root.elements["a"].attribute("xml:lang").value)
    end

    def test_language_fixup_does_not_override_included_language
      write("a.xml", %q{<a xml:lang="de"/>})
      doc = process(wrap(%{<xi:include href="a.xml"/>}, %{xml:lang="fr"}))
      assert_equal("de", doc.root.elements["a"].attribute("xml:lang").value)
    end

    def test_language_fixup_absent_without_in_scope_language
      write("a.xml", "<a/>")
      doc = process(wrap(%{<xi:include href="a.xml"/>}))
      assert_nil(doc.root.elements["a"].attribute("xml:lang"))
    end

    # -- parse=text ----------------------------------------------------

    def test_parse_text
      write("a.txt", "hello <world> & you")
      doc = process(wrap(%{<xi:include href="a.txt" parse="text"/>}))
      assert_equal("hello <world> & you", doc.root.text.strip)
      assert_match(/&lt;world&gt;/, doc.root.to_s)
    end

    def test_parse_text_does_not_receive_language_fixup
      write("a.txt", "hello")
      doc = process(wrap(%{<xi:include href="a.txt" parse="text"/>}, %{xml:lang="fr"}))
      assert_equal("hello", doc.root.text.strip)
      # Language fixup applies to element information items only; the
      # included text is a single text node and adds no markup.
      assert(doc.root.children.one? { |child| child.is_a?(REXML::Text) })
    end

    def test_parse_text_with_encoding_attribute
      write("a.txt", "caf\u00e9".encode("ISO-8859-1").b)
      doc = process(wrap(%{<xi:include href="a.txt" parse="text" encoding="ISO-8859-1"/>}))
      assert_equal("caf\u00e9", doc.root.text)
    end

    def test_parse_text_utf8_bom_is_stripped
      write("a.txt", "\uFEFFbom".b)
      doc = process(wrap(%{<xi:include href="a.txt" parse="text"/>}))
      assert_equal("bom", doc.root.text)
    end

    def test_parse_text_encoding_mismatch_is_resource_error
      write("a.txt", "\xFF\xFE".b + "x".b)
      assert_raise(REXML::XInclude::EncodingError) do
        process(wrap(%{<xi:include href="a.txt" parse="text" encoding="UTF-8"/>}))
      end
    end

    # -- fallback ------------------------------------------------------

    def test_fallback_is_used_when_resource_missing
      doc = process(wrap(%{<xi:include href="missing.xml"><xi:fallback><b>fb</b></xi:fallback></xi:include>}))
      assert_equal("fb", doc.root.elements["b"].text)
    end

    def test_fallback_can_contain_nested_include
      write("fb.xml", "<fb/>")
      source = %{<xi:include href="missing.xml"><xi:fallback><xi:include href="fb.xml"/></xi:fallback></xi:include>}
      doc = process(wrap(source))
      assert_not_nil(doc.root.elements["fb"])
    end

    def test_empty_fallback_removes_include
      doc = process(wrap(%{<xi:include href="missing.xml"><xi:fallback/></xi:include>}))
      assert(doc.root.children.all? { |child| child.is_a?(REXML::Text) })
    end

    def test_missing_without_fallback_raises_resource_error
      assert_raise(REXML::XInclude::ResourceError) do
        process(wrap(%{<xi:include href="missing.xml"/>}))
      end
    end

    def test_unparseable_xml_with_fallback_uses_fallback
      write("bad.xml", "<a><b></a>")
      doc = process(wrap(%{<xi:include href="bad.xml"><xi:fallback>ok</xi:fallback></xi:include>}))
      assert_equal("ok", doc.root.text.strip)
    end

    def test_multiple_fallbacks_is_fatal
      source = %{<xi:include href="m.xml"><xi:fallback/><xi:fallback/></xi:include>}
      assert_raise(REXML::XInclude::FatalError) { process(wrap(source)) }
    end

    # -- fragments (general parsed entities) --------------------------

    def test_fragment_with_multiple_top_level_elements
      write("frag.xml", "<x>1</x><y>2</y>")
      doc = process(wrap(%{<xi:include href="frag.xml"/>}))
      assert_equal("1", doc.root.elements["x"].text)
      assert_equal("2", doc.root.elements["y"].text)
    end

    def test_fragment_inherits_default_namespace
      write("frag.xml", "<child/>")
      doc = process(%Q{<r xmlns=\"urn:example\" xmlns:xi=\"#{XI}\"><xi:include href=\"frag.xml\"/></r>})
      child = doc.root.children.find { |node| node.is_a?(REXML::Element) }
      assert_equal("child", child.name)
      assert_equal("urn:example", child.namespace)
    end

    def test_full_document_keeps_own_default_namespace
      write("full.xml", %Q{<x xmlns=\"urn:other\"/>})
      doc = %Q{<r xmlns=\"urn:example\" xmlns:xi=\"#{XI}\"><xi:include href=\"full.xml\"/></r>}
      document = process(doc)
      child = document.root.children.find { |node| node.is_a?(REXML::Element) }
      assert_equal("urn:other", child.namespace)
    end

    # -- include loops -------------------------------------------------

    def test_include_loop_raises_with_full_chain
      write("c1.xml", %Q{<a xmlns:xi=\"#{XI}\"><xi:include href=\"c2.xml\"/></a>})
      write("c2.xml", %Q{<b xmlns:xi=\"#{XI}\"><xi:include href=\"c1.xml\"/></b>})
      error = assert_raise(REXML::XInclude::LoopError) do
        process(wrap(%{<xi:include href="c1.xml"/>}))
      end
      chain = error.chain.collect(&:to_s)
      assert_equal(3, chain.length)
      assert_equal(chain.first, chain.last)
      assert_match(/XInclude loop detected/, error.message)
    end

    def test_self_referencing_include_is_a_loop
      write("self.xml", %Q{<a xmlns:xi=\"#{XI}\"><xi:include href=\"self.xml\"/></a>})
      assert_raise(REXML::XInclude::LoopError) do
        process(wrap(%{<xi:include href="self.xml"/>}))
      end
    end

    def test_loop_inside_fallback_reports_full_chain
      write("x1.xml", %Q{<a xmlns:xi=\"#{XI}\"><xi:include href=\"x2.xml\"><xi:fallback><xi:include href=\"x1.xml\"/></xi:fallback></xi:include></a>})
      write("x2.xml", %Q{<b xmlns:xi=\"#{XI}\"><xi:include href=\"x3.xml\"><xi:fallback><xi:include href=\"x1.xml\"/></xi:fallback></xi:include></b>})
      write("x3.xml", "not xml")
      error = assert_raise(REXML::XInclude::LoopError) do
        process(wrap(%{<xi:include href="x1.xml"/>}))
      end
      names = error.chain.map { |uri| File.basename(uri.path) }
      assert_equal(%w[x1.xml x2.xml x3.xml x1.xml], names)
    end

    # -- XPointer is explicitly rejected ------------------------------

    def test_xpointer_attribute_is_rejected
      assert_raise(REXML::XInclude::UnsupportedXPointerError) do
        process(wrap(%{<xi:include href="a.xml" xpointer="xpointer(/r)"/>}))
      end
    end

    def test_fragment_identifier_is_rejected
      assert_raise(REXML::XInclude::UnsupportedXPointerError) do
        process(wrap(%{<xi:include href="a.xml#id"/>}))
      end
    end

    # -- resolver ------------------------------------------------------

    def test_resolver_provides_uri_and_context
      write("a.xml", "<a/>")
      seen = nil
      resolver = lambda do |uri, context|
        seen = [uri, context]
        File.binread(File.join(@tmpdir, File.basename(uri.path)))
      end
      process(wrap(%{<xi:include href="a.xml" parse="xml" accept="text/xml" accept-language="en"/>}),
              resolver: resolver)
      assert_not_nil(seen)
      assert_equal("xml", seen[1][:parse])
      assert_equal("text/xml", seen[1][:accept])
      assert_equal("en", seen[1][:accept_language])
      assert_kind_of(URI::Generic, seen[0])
    end

    def test_single_argument_proc_resolver
      write("a.xml", "<a>ok</a>")
      seen = []
      resolver = lambda { |uri| seen << uri; File.binread(File.join(@tmpdir, File.basename(uri.path))) }
      doc = process(wrap(%{<xi:include href="a.xml"/>}), resolver: resolver)
      assert_equal("ok", doc.root.elements["a"].text)
      assert_equal(1, seen.length)
    end

    def test_resolver_failure_uses_fallback
      resolver = lambda { |uri, context| raise REXML::XInclude::ResourceError.new("nope") }
      doc = process(wrap(%{<xi:include href="a.xml"><xi:fallback>fb</xi:fallback></xi:include>}),
                       resolver: resolver)
      assert_equal("fb", doc.root.text.strip)
    end

    def test_default_resolver_does_not_access_network
      error = assert_raise(REXML::XInclude::ResourceError) do
        process(wrap(%{<xi:include href="http://example.com/a.xml"/>}))
      end
      assert_match(/unsupported URI scheme/, error.message)
    end

    # -- fatal markup errors ------------------------------------------

    def test_invalid_parse_value_is_fatal
      assert_raise(REXML::XInclude::FatalError) do
        process(wrap(%{<xi:include href="a.xml" parse="bogus"/>}))
      end
    end

    def test_non_whitespace_text_inside_include_is_fatal
      source = %{<xi:include href="a.xml">text</xi:include>}
      assert_raise(REXML::XInclude::FatalError) { process(wrap(source)) }
    end

    def test_comments_and_processing_instructions_inside_include_ignored
      write("a.xml", "<a/>")
      source = %{<xi:include href="a.xml"><!-- c --><?pi data?></xi:include>}
      doc = process(wrap(source))
      assert_not_nil(doc.root.elements["a"])
    end

    def test_unknown_xinclude_namespace_element_inside_include_is_fatal
      source = %Q{<xi:include href="a.xml"><xi:bogus/></xi:include>}
      assert_raise(REXML::XInclude::FatalError) { process(wrap(source)) }
    end

    # -- multiple includes --------------------------------------------

    def test_multiple_includes
      write("a.xml", "<a>1</a>")
      write("b.xml", "<b>2</b>")
      doc = process(wrap(%{<xi:include href="a.xml"/><xi:include href="b.xml"/>}))
      assert_equal("1", doc.root.elements["a"].text)
      assert_equal("2", doc.root.elements["b"].text)
    end

    def test_same_resource_included_twice
      write("a.xml", "<a/>")
      doc = process(wrap(%{<xi:include href="a.xml"/><xi:include href="a.xml"/>}))
      assert_equal(2, doc.root.children.count { |child| child.is_a?(REXML::Element) })
    end

    # -- processing an element subtree --------------------------------

    def test_process_element_subtree
      write("a.xml", "<a/>")
      doc = REXML::Document.new(%Q{<root xmlns:xi=\"#{XI}\"><xi:include href=\"a.xml\"/></root>})
      REXML::XInclude.process(doc.root, base_uri: file_uri(File.join(@tmpdir, "m.xml")))
      assert_not_nil(doc.root.elements["a"])
    end

    def test_relative_path_base_uri_string
      write("a.xml", "<a/>")
      Dir.chdir(@tmpdir) do
        doc = REXML::Document.new(%Q{<r xmlns:xi=\"#{XI}\"><xi:include href=\"a.xml\"/></r>})
        REXML::XInclude.process(doc)
        assert_not_nil(doc.root.elements["a"])
      end
    end
  end
end
