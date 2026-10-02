# frozen_string_literal: false

require "fileutils"
require "tmpdir"

require "rexml/document"

module REXMLTests
  class TestXInclude < Test::Unit::TestCase
    XI = REXML::XInclude::NAMESPACE

    def process(xml, resolver:, base_uri: "/doc.xml")
      document = REXML::Document.new(xml)
      REXML::XInclude.new(resolver: resolver).process(document,
                                                      base_uri: base_uri)
      document
    end

    def hash_resolver(files)
      lambda do |uri|
        raise "no such resource: #{uri}" unless files.key?(uri)
        files[uri]
      end
    end

    def test_include_xml_basic
      document = process(<<-XML, resolver: hash_resolver("/chunk.xml" => "<chunk><sub/></chunk>"))
<root xmlns:xi="#{XI}"><xi:include href="chunk.xml"/></root>
      XML
      assert_equal("chunk", document.root.elements[1].name)
      assert_equal("sub", document.root.elements["chunk"].elements[1].name)
    end

    def test_include_xml_default_namespace
      document = process(<<-XML, resolver: hash_resolver("/chunk.xml" => "<chunk/>"))
<root xmlns="#{XI}"><include href="chunk.xml"/></root>
      XML
      assert_equal("chunk", document.root.elements[1].name)
    end

    def test_include_xml_returns_document
      document = REXML::Document.new("<root/>")
      result = REXML::XInclude.new(resolver: hash_resolver({})).process(document)
      assert_same(document, result)
    end

    def test_include_text
      document = process(<<-XML, resolver: hash_resolver("/note.txt" => "a < b & c"))
<root xmlns:xi="#{XI}"><xi:include parse="text" href="note.txt"/></root>
      XML
      assert_equal("a < b & c", document.root.text)
      assert_include(document.to_s, "a &lt; b &amp; c")
    end

    def test_include_text_fallback_on_missing_resource
      document = process(<<-XML, resolver: hash_resolver({}))
<root xmlns:xi="#{XI}">
  <xi:include parse="text" href="missing.txt"><xi:fallback>default</xi:fallback></xi:include>
</root>
      XML
      assert_equal("default", document.root.texts.join.strip)
    end

    def test_fallback_used_on_resource_error
      document = process(<<-XML, resolver: hash_resolver({}))
<root xmlns:xi="#{XI}">
  <xi:include href="missing.xml"><xi:fallback><fb>fallback</fb></xi:fallback></xi:include>
</root>
      XML
      assert_equal("fallback", document.root.elements["fb"].text)
    end

    def test_empty_fallback_removes_include
      document = process(<<-XML, resolver: hash_resolver({}))
<root xmlns:xi="#{XI}"><xi:include href="missing.xml"><xi:fallback/></xi:include></root>
      XML
      assert_equal(0, document.root.elements.size)
    end

    def test_resource_error_without_fallback
      error = assert_raise(REXML::XInclude::ResourceError) do
        process(<<-XML, resolver: hash_resolver({}))
<root xmlns:xi="#{XI}"><xi:include href="missing.xml"/></root>
        XML
      end
      assert_equal("/missing.xml", error.href)
    end

    def test_fallback_with_nested_include_is_processed
      files = {
        "/real.xml" => "<real/>",
      }
      document = process(<<-XML, resolver: hash_resolver(files))
<root xmlns:xi="#{XI}">
  <xi:include href="missing.xml">
    <xi:fallback><xi:include href="real.xml"/></xi:fallback>
  </xi:include>
</root>
      XML
      assert_equal("real", document.root.elements[1].name)
    end

    def test_multiple_fallbacks_rejected
      assert_raise(REXML::XInclude::FatalError) do
        process(<<-XML, resolver: hash_resolver({}))
<root xmlns:xi="#{XI}">
  <xi:include href="missing.xml">
    <xi:fallback>a</xi:fallback>
    <xi:fallback>b</xi:fallback>
  </xi:include>
</root>
        XML
      end
    end

    def test_nested_include_resolves_against_including_resource
      files = {
        "/main/a.xml" =>
          %(<a xmlns:xi="#{XI}"><xi:include href="sub/b.xml"/></a>),
        "/main/sub/b.xml" =>
          %(<b xmlns:xi="#{XI}"><xi:include parse="text" href="c.txt"/></b>),
        "/main/sub/c.txt" => "deep",
      }
      document = process(<<-XML, resolver: hash_resolver(files), base_uri: "/doc.xml")
<root xmlns:xi="#{XI}"><xi:include href="main/a.xml"/></root>
      XML
      assert_equal("deep", document.root.elements["a"].elements["b"].text)
    end

    def test_xpointer_rejected
      error = assert_raise(REXML::XInclude::XPointerNotSupportedError) do
        process(<<-XML, resolver: hash_resolver({}))
<root xmlns:xi="#{XI}">
  <xi:include href="a.xml" xpointer="xpointer(/a/b)">
    <xi:fallback>ignored</xi:fallback>
  </xi:include>
</root>
        XML
      end
      assert_kind_of(REXML::XInclude::FatalError, error)
    end

    def test_invalid_parse_value_rejected
      assert_raise(REXML::XInclude::FatalError) do
        process(<<-XML, resolver: hash_resolver({}))
<root xmlns:xi="#{XI}"><xi:include parse="html" href="a.html"/></root>
        XML
      end
    end

    def test_missing_href_rejected
      assert_raise(REXML::XInclude::FatalError) do
        process(<<-XML, resolver: hash_resolver({}))
<root xmlns:xi="#{XI}"><xi:include/></root>
        XML
      end
    end

    def test_malformed_included_xml_is_fatal_error
      files = {"/broken.xml" => "<broken"}
      error = assert_raise(REXML::XInclude::FatalError) do
        process(<<-XML, resolver: hash_resolver(files))
<root xmlns:xi="#{XI}">
  <xi:include href="broken.xml"><xi:fallback>ignored</xi:fallback></xi:include>
</root>
        XML
      end
      assert_match(/not well-formed/, error.message)
    end

    def test_loop_detection_reports_full_chain
      files = {
        "/a.xml" => %(<a xmlns:xi="#{XI}"><xi:include href="b.xml"/></a>),
        "/b.xml" => %(<b xmlns:xi="#{XI}"><xi:include href="a.xml"/></b>),
      }
      error = assert_raise(REXML::XInclude::LoopError) do
        process(files["/a.xml"], resolver: hash_resolver(files),
                                base_uri: "/a.xml")
      end
      assert_equal(["/a.xml", "/b.xml", "/a.xml"], error.chain)
      assert_equal("XInclude loop detected: /a.xml -> /b.xml -> /a.xml",
                   error.message)
    end

    def test_self_inclusion_is_a_loop
      files = {
        "/self.xml" => %(<s xmlns:xi="#{XI}"><xi:include href="self.xml"/></s>),
      }
      error = assert_raise(REXML::XInclude::LoopError) do
        process(files["/self.xml"], resolver: hash_resolver(files),
                                    base_uri: "/self.xml")
      end
      assert_equal(["/self.xml", "/self.xml"], error.chain)
    end

    def test_same_resource_included_twice_is_not_a_loop
      files = {"/chunk.xml" => "<chunk/>"}
      document = process(<<-XML, resolver: hash_resolver(files), base_uri: "/doc.xml")
<root xmlns:xi="#{XI}">
  <xi:include href="chunk.xml"/>
  <xi:include href="chunk.xml"/>
</root>
      XML
      assert_equal(2, document.root.elements.size)
    end

    def test_xml_base_in_scope_affects_resolution
      seen = []
      resolver = lambda do |uri|
        seen << uri
        "<chunk/>"
      end
      process(<<-XML, resolver: resolver, base_uri: "/docs/doc.xml")
<root xmlns:xi="#{XI}">
  <section xml:base="parts/"><xi:include href="ch1.xml"/></section>
</root>
      XML
      assert_equal(["/docs/parts/ch1.xml"], seen)
    end

    def test_base_uri_fixup_keeps_relative_references_stable
      files = {
        "/shared/chunk.xml" => %(<chunk><ref href="data.txt"/></chunk>),
      }
      xml = <<~XML
        <doc xmlns:xi="#{XI}"><xi:include href="../shared/chunk.xml"/></doc>
      XML
      resolved_references = ["/a/doc.xml", "/b/doc.xml"].map do |base_uri|
        document = process(xml, resolver: hash_resolver(files),
                                base_uri: base_uri)
        chunk = document.root.elements["chunk"]
        REXML::XInclude.resolve_uri(chunk.attributes["xml:base"], "data.txt")
      end
      assert_equal("/shared/data.txt", resolved_references[0])
      assert_equal(resolved_references[0], resolved_references[1])
    end

    def test_base_uri_fixup_resolves_existing_xml_base
      files = {
        "/shared/chunk.xml" => %(<chunk xml:base="sub/"><ref href="d.txt"/></chunk>),
      }
      document = process(<<-XML, resolver: hash_resolver(files), base_uri: "/a/doc.xml")
<root xmlns:xi="#{XI}"><xi:include href="../shared/chunk.xml"/></root>
      XML
      chunk = document.root.elements["chunk"]
      assert_equal("/shared/sub/", chunk.attributes["xml:base"])
      assert_equal("/shared/sub/d.txt",
                   REXML::XInclude.resolve_uri(chunk.attributes["xml:base"],
                                               "d.txt"))
    end

    def test_base_uri_fixup_records_included_resource_uri
      files = {"/chunk.xml" => "<chunk/>"}
      document = process(<<-XML, resolver: hash_resolver(files), base_uri: "/doc.xml")
<root xmlns:xi="#{XI}"><xi:include href="chunk.xml"/></root>
      XML
      assert_equal("/chunk.xml",
                   document.root.elements["chunk"].attributes["xml:base"])
    end

    def test_xml_lang_inherited_from_include_location
      files = {"/chunk.xml" => "<chunk/>"}
      document = process(<<-XML, resolver: hash_resolver(files), base_uri: "/doc.xml")
<root xml:lang="ja" xmlns:xi="#{XI}"><xi:include href="chunk.xml"/></root>
      XML
      assert_equal("ja", document.root.elements["chunk"].attributes["xml:lang"])
    end

    def test_xml_lang_not_overridden
      files = {"/chunk.xml" => %(<chunk xml:lang="en"/>)}
      document = process(<<-XML, resolver: hash_resolver(files), base_uri: "/doc.xml")
<root xml:lang="ja" xmlns:xi="#{XI}"><xi:include href="chunk.xml"/></root>
      XML
      assert_equal("en", document.root.elements["chunk"].attributes["xml:lang"])
    end

    def test_default_resolver_reads_local_files
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "chunk.xml"), "<chunk>local</chunk>")
        document = REXML::Document.new(<<-XML)
<root xmlns:xi="#{XI}"><xi:include href="chunk.xml"/></root>
        XML
        REXML::XInclude.new.process(document,
                                    base_uri: File.join(dir, "doc.xml"))
        assert_equal("local", document.root.elements["chunk"].text)
      end
    end

    def test_default_resolver_refuses_network_access
      document = REXML::Document.new(<<-XML)
<root xmlns:xi="#{XI}"><xi:include href="http://example.com/x.xml"/></root>
      XML
      error = assert_raise(REXML::XInclude::ResourceError) do
        REXML::XInclude.new.process(document)
      end
      assert_match(/network access is disabled/, error.message)
    end

    def test_resolver_receives_resolved_uri
      seen = []
      resolver = lambda do |uri|
        seen << uri
        "<chunk/>"
      end
      process(<<-XML, resolver: resolver, base_uri: "/dir/a/doc.xml")
<root xmlns:xi="#{XI}"><xi:include href="../shared/chunk.xml"/></root>
      XML
      assert_equal(["/dir/shared/chunk.xml"], seen)
    end

    def test_resolver_nil_content_is_resource_error
      resolver = ->(uri) { nil }
      assert_raise(REXML::XInclude::ResourceError) do
        process(<<-XML, resolver: resolver)
<root xmlns:xi="#{XI}"><xi:include href="a.xml"/></root>
        XML
      end
    end

    def test_resolve_uri
      assert_equal("/a/b/c.xml",
                   REXML::XInclude.resolve_uri("/a/b/doc.xml", "c.xml"))
      assert_equal("/a/c.xml",
                   REXML::XInclude.resolve_uri("/a/b/doc.xml", "../c.xml"))
      assert_equal("https://example.com/x.xml",
                   REXML::XInclude.resolve_uri("/a/b.xml",
                                               "https://example.com/x.xml"))
      assert_equal("file:///a/c.xml",
                   REXML::XInclude.resolve_uri("file:///a/b/doc.xml",
                                               "../c.xml"))
      assert_equal("c.xml", REXML::XInclude.resolve_uri(nil, "c.xml"))
    end
  end
end
