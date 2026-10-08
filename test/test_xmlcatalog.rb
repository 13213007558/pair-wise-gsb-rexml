# frozen_string_literal: true

require "rexml/xmlcatalog"

module REXMLTests
  class TestXMLCatalog < Test::Unit::TestCase
    NS = 'xmlns="urn:oasis:names:tc:entity:xmlns:xml:catalog"'

    private

    def catalog(entries, prefer: nil, xml_base: nil)
      attributes = +""
      attributes << %( prefer="#{prefer}") if prefer
      attributes << %( xml:base="#{xml_base}") if xml_base
      "<catalog #{NS}#{attributes}>#{entries}</catalog>"
    end

    def resolver_with(xml, uri: nil, loader: nil)
      resolver = REXML::XMLCatalog::Resolver.new(loader: loader)
      resolver.add_catalog(xml, uri: uri)
      resolver
    end

    class TestExactMatch < self
      def test_system
        xml = catalog(<<-XML)
<system systemId="http://example.com/a.dtd" uri="mirror/a.dtd"/>
        XML
        resolver = resolver_with(xml, uri: "app:///catalog.xml")
        plan = resolver.resolve(system_id: "http://example.com/a.dtd")
        assert_equal("app:///mirror/a.dtd", plan.uri)
        assert_equal(:system, plan.match)
        assert_equal("http://example.com/a.dtd", plan.identifier)
        assert_equal("app:///catalog.xml", plan.catalog_uri)
        assert_equal(["app:///catalog.xml"], plan.catalog_chain)
      end

      def test_unmatched_returns_nil
        resolver = resolver_with(catalog("<system systemId='a' uri='b'/>"))
        assert_nil(resolver.resolve(system_id: "zzz"))
        assert_nil(resolver.resolve)
      end

      def test_public
        xml = catalog(<<-XML)
<public publicId="-//EX//DTD a//EN" uri="mirror/a.dtd"/>
        XML
        plan = resolver_with(xml).resolve(public_id: "-//EX//DTD a//EN")
        assert_equal("mirror/a.dtd", plan.uri)
        assert_equal(:public, plan.match)
      end

      def test_public_id_is_normalized
        xml = catalog(<<-XML)
<public publicId="-//EX//DTD  a//EN" uri="mirror/a.dtd"/>
        XML
        plan = resolver_with(xml).resolve(public_id: "-//EX//DTD\n\ta//EN")
        assert_equal("mirror/a.dtd", plan.uri)
      end

      def test_uri
        xml = catalog(<<-XML)
<uri name="urn:example:style" uri="styles/default.xsl"/>
        XML
        resolver = resolver_with(xml)
        plan = resolver.resolve_uri("urn:example:style")
        assert_equal("styles/default.xsl", plan.uri)
        assert_equal(:uri, plan.match)
        assert_nil(resolver.resolve_uri("urn:example:other"))
      end

      def test_catalog_without_namespace_is_accepted
        resolver = resolver_with("<catalog><system systemId='a' uri='b'/></catalog>")
        assert_equal("b", resolver.resolve(system_id: "a").uri)
      end
    end

    class TestRewriteAndSuffix < self
      def test_rewrite_system_longest_prefix_wins
        xml = catalog(<<-XML)
<rewriteSystem systemIdStartString="http://example.com/" rewritePrefix="generic/"/>
<rewriteSystem systemIdStartString="http://example.com/dtd/" rewritePrefix="dtd/"/>
        XML
        resolver = resolver_with(xml, uri: "app:///cat/catalog.xml")
        plan = resolver.resolve(system_id: "http://example.com/dtd/a.dtd")
        assert_equal("app:///cat/dtd/a.dtd", plan.uri)
        assert_equal(:rewrite_system, plan.match)
        plan = resolver.resolve(system_id: "http://example.com/other/x.ent")
        assert_equal("app:///cat/generic/other/x.ent", plan.uri)
      end

      def test_system_suffix_longest_wins
        xml = catalog(<<-XML)
<systemSuffix systemIdSuffix=".dtd" uri="fallback.dtd"/>
<systemSuffix systemIdSuffix="a.dtd" uri="mirror/a.dtd"/>
        XML
        resolver = resolver_with(xml, uri: "app:///catalog.xml")
        plan = resolver.resolve(system_id: "http://example.com/a.dtd")
        assert_equal("app:///mirror/a.dtd", plan.uri)
        assert_equal(:system_suffix, plan.match)
        plan = resolver.resolve(system_id: "http://example.com/b.dtd")
        assert_equal("app:///fallback.dtd", plan.uri)
      end

      def test_rewrite_uri_and_uri_suffix
        xml = catalog(<<-XML)
<rewriteURI uriStartString="urn:example:lib:" rewritePrefix="lib/"/>
<uriSuffix uriSuffix=".rng" uri="schemas/relax.rng"/>
        XML
        resolver = resolver_with(xml, uri: "app:///catalog.xml")
        plan = resolver.resolve_uri("urn:example:lib:core")
        assert_equal("app:///lib/core", plan.uri)
        assert_equal(:rewrite_uri, plan.match)
        plan = resolver.resolve_uri("http://example.com/schema.rng")
        assert_equal("app:///schemas/relax.rng", plan.uri)
        assert_equal(:uri_suffix, plan.match)
      end
    end

    class TestLookupOrder < self
      def test_exact_beats_rewrite_and_delegate
        xml = catalog(<<-XML)
<system systemId="http://example.com/a.dtd" uri="exact/a.dtd"/>
<rewriteSystem systemIdStartString="http://example.com/" rewritePrefix="rewritten/"/>
<delegateSystem systemIdStartString="http://example.com/" catalog="sub.xml"/>
        XML
        loaded = []
        loader = ->(uri) { loaded << uri; nil }
        resolver = resolver_with(xml, uri: "app:///catalog.xml", loader: loader)
        plan = resolver.resolve(system_id: "http://example.com/a.dtd")
        assert_equal(:system, plan.match)
        assert_equal("app:///exact/a.dtd", plan.uri)
        assert_equal([], loaded)
      end

      def test_rewrite_beats_delegate
        xml = catalog(<<-XML)
<rewriteSystem systemIdStartString="http://example.com/" rewritePrefix="rewritten/"/>
<delegateSystem systemIdStartString="http://example.com/" catalog="sub.xml"/>
        XML
        loaded = []
        loader = ->(uri) { loaded << uri; nil }
        resolver = resolver_with(xml, uri: "app:///catalog.xml", loader: loader)
        plan = resolver.resolve(system_id: "http://example.com/b.dtd")
        assert_equal(:rewrite_system, plan.match)
        assert_equal("app:///rewritten/b.dtd", plan.uri)
        assert_equal([], loaded)
      end

      def test_delegate_used_when_nothing_else_matches
        catalogs = {
          "app:///sub.xml" =>
            catalog("<system systemId='http://example.com/c.dtd' uri='sub/c.dtd'/>"),
        }
        xml = catalog(<<-XML)
<rewriteSystem systemIdStartString="http://other.example/" rewritePrefix="rewritten/"/>
<delegateSystem systemIdStartString="http://example.com/" catalog="sub.xml"/>
        XML
        loaded = []
        loader = ->(uri) { loaded << uri; catalogs[uri] }
        resolver = resolver_with(xml, uri: "app:///catalog.xml", loader: loader)
        plan = resolver.resolve(system_id: "http://example.com/c.dtd")
        assert_equal("app:///sub/c.dtd", plan.uri)
        assert_equal("app:///sub.xml", plan.catalog_uri)
        assert_equal(["app:///catalog.xml", "app:///sub.xml"], plan.catalog_chain)
        assert_equal(["app:///sub.xml"], loaded)
      end
    end

    class TestPrefer < self
      def test_public_match_preferred_by_default
        xml = catalog(<<-XML)
<public publicId="-//EX//DTD a//EN" uri="from-public/a.dtd"/>
<rewriteSystem systemIdStartString="http://example.com/" rewritePrefix="rewritten/"/>
        XML
        plan = resolver_with(xml).resolve(system_id: "http://example.com/a.dtd",
                                          public_id: "-//EX//DTD a//EN")
        assert_equal(:public, plan.match)
        assert_equal("from-public/a.dtd", plan.uri)
      end

      def test_prefer_system_ignores_public_when_system_id_given
        xml = catalog(<<-XML, prefer: "system")
<public publicId="-//EX//DTD a//EN" uri="from-public/a.dtd"/>
<rewriteSystem systemIdStartString="http://example.com/" rewritePrefix="rewritten/"/>
        XML
        plan = resolver_with(xml).resolve(system_id: "http://example.com/a.dtd",
                                          public_id: "-//EX//DTD a//EN")
        assert_equal(:rewrite_system, plan.match)
        assert_equal("rewritten/a.dtd", plan.uri)
      end

      def test_prefer_system_still_resolves_public_without_system_id
        xml = catalog(<<-XML, prefer: "system")
<public publicId="-//EX//DTD a//EN" uri="from-public/a.dtd"/>
        XML
        plan = resolver_with(xml).resolve(public_id: "-//EX//DTD a//EN")
        assert_equal(:public, plan.match)
      end

      def test_group_scoped_prefer
        xml = catalog(<<-XML, prefer: "system")
<group prefer="public">
  <public publicId="-//EX//DTD a//EN" uri="from-public/a.dtd"/>
</group>
        XML
        plan = resolver_with(xml).resolve(system_id: "http://example.com/a.dtd",
                                          public_id: "-//EX//DTD a//EN")
        assert_equal(:public, plan.match)
      end
    end

    class TestDelegation < self
      def test_delegate_system_longest_prefix_first
        catalogs = {
          "app:///generic.xml" =>
            catalog("<system systemId='http://example.com/a.dtd' uri='generic/a.dtd'/>"),
          "app:///dtd.xml" =>
            catalog("<system systemId='http://example.com/dtd/a.dtd' uri='dtd/a.dtd'/>"),
        }
        xml = catalog(<<-XML)
<delegateSystem systemIdStartString="http://example.com/" catalog="generic.xml"/>
<delegateSystem systemIdStartString="http://example.com/dtd/" catalog="dtd.xml"/>
        XML
        loaded = []
        loader = ->(uri) { loaded << uri; catalogs[uri] }
        resolver = resolver_with(xml, uri: "app:///catalog.xml", loader: loader)
        plan = resolver.resolve(system_id: "http://example.com/dtd/a.dtd")
        assert_equal("app:///dtd/a.dtd", plan.uri)
        assert_equal("app:///dtd.xml", plan.catalog_uri)
        assert_equal(["app:///dtd.xml"], loaded)
      end

      def test_delegate_falls_back_to_shorter_prefix
        catalogs = {
          "app:///generic.xml" =>
            catalog("<system systemId='http://example.com/dtd/a.dtd' uri='generic/a.dtd'/>"),
          "app:///dtd.xml" =>
            catalog("<system systemId='urn:no-match' uri='x'/>"),
        }
        xml = catalog(<<-XML)
<delegateSystem systemIdStartString="http://example.com/" catalog="generic.xml"/>
<delegateSystem systemIdStartString="http://example.com/dtd/" catalog="dtd.xml"/>
        XML
        loaded = []
        loader = ->(uri) { loaded << uri; catalogs[uri] }
        resolver = resolver_with(xml, uri: "app:///catalog.xml", loader: loader)
        plan = resolver.resolve(system_id: "http://example.com/dtd/a.dtd")
        assert_equal("app:///generic/a.dtd", plan.uri)
        assert_equal("app:///generic.xml", plan.catalog_uri)
        assert_equal(["app:///dtd.xml", "app:///generic.xml"], loaded)
      end

      def test_equal_length_delegates_in_document_order
        catalogs = {
          "app:///first.xml" =>
            catalog("<system systemId='urn:no-match' uri='x'/>"),
          "app:///second.xml" =>
            catalog("<system systemId='http://example.com/a.dtd' uri='second/a.dtd'/>"),
        }
        xml = catalog(<<-XML)
<delegateSystem systemIdStartString="http://example.com/" catalog="first.xml"/>
<delegateSystem systemIdStartString="http://example.com/" catalog="second.xml"/>
        XML
        loaded = []
        loader = ->(uri) { loaded << uri; catalogs[uri] }
        resolver = resolver_with(xml, uri: "app:///catalog.xml", loader: loader)
        plan = resolver.resolve(system_id: "http://example.com/a.dtd")
        assert_equal("app:///second/a.dtd", plan.uri)
        assert_equal(["app:///first.xml", "app:///second.xml"], loaded)
      end

      def test_delegate_public
        catalogs = {
          "app:///pub.xml" =>
            catalog("<public publicId='-//EX//DTD a//EN' uri='pub/a.dtd'/>"),
        }
        xml = catalog(<<-XML)
<delegatePublic publicIdStartString="-//EX//" catalog="pub.xml"/>
        XML
        resolver = resolver_with(xml, uri: "app:///catalog.xml",
                                 loader: ->(uri) { catalogs[uri] })
        plan = resolver.resolve(public_id: "-//EX//DTD a//EN")
        assert_equal("app:///pub/a.dtd", plan.uri)
        assert_equal(:public, plan.match)
      end

      def test_delegate_uri
        catalogs = {
          "app:///u.xml" => catalog("<uri name='urn:example:x' uri='u/x'/>"),
        }
        xml = catalog(<<-XML)
<delegateURI uriStartString="urn:example:" catalog="u.xml"/>
        XML
        resolver = resolver_with(xml, uri: "app:///catalog.xml",
                                 loader: ->(uri) { catalogs[uri] })
        plan = resolver.resolve_uri("urn:example:x")
        assert_equal("app:///u/x", plan.uri)
      end

      def test_missing_delegate_catalog_is_treated_as_empty
        xml = catalog(<<-XML)
<delegateSystem systemIdStartString="http://example.com/" catalog="missing.xml"/>
        XML
        resolver = resolver_with(xml, uri: "app:///catalog.xml",
                                 loader: ->(uri) { nil })
        assert_nil(resolver.resolve(system_id: "http://example.com/a.dtd"))
      end

      def test_broken_delegate_catalog_is_treated_as_empty
        xml = catalog(<<-XML)
<delegateSystem systemIdStartString="http://example.com/" catalog="broken.xml"/>
        XML
        resolver = resolver_with(xml, uri: "app:///catalog.xml",
                                 loader: ->(uri) { "<catalog" })
        assert_nil(resolver.resolve(system_id: "http://example.com/a.dtd"))
      end

      def test_loader_error_propagates
        xml = catalog(<<-XML)
<delegateSystem systemIdStartString="http://example.com/" catalog="sub.xml"/>
        XML
        resolver = resolver_with(xml, uri: "app:///catalog.xml",
                                 loader: ->(uri) { raise "denied by policy" })
        error = assert_raise(RuntimeError) do
          resolver.resolve(system_id: "http://example.com/a.dtd")
        end
        assert_equal("denied by policy", error.message)
      end

      def test_no_loader_means_no_catalog_io
        xml = catalog(<<-XML)
<delegateSystem systemIdStartString="http://example.com/" catalog="file:///etc/passwd"/>
<nextCatalog catalog="file:///etc/passwd"/>
        XML
        resolver = resolver_with(xml, uri: "app:///catalog.xml")
        assert_nil(resolver.resolve(system_id: "http://example.com/a.dtd"))
      end
    end

    class TestNextCatalog < self
      def test_next_catalog_fallback
        catalogs = {
          "app:///more.xml" =>
            catalog("<system systemId='http://example.com/a.dtd' uri='more/a.dtd'/>"),
        }
        xml = catalog(<<-XML)
<nextCatalog catalog="more.xml"/>
        XML
        resolver = resolver_with(xml, uri: "app:///catalog.xml",
                                 loader: ->(uri) { catalogs[uri] })
        plan = resolver.resolve(system_id: "http://example.com/a.dtd")
        assert_equal("app:///more/a.dtd", plan.uri)
        assert_equal("app:///more.xml", plan.catalog_uri)
      end

      def test_multiple_root_catalogs_in_registration_order
        one = catalog(<<-XML)
<system systemId="http://example.com/a.dtd" uri="one/a.dtd"/>
        XML
        two = catalog(<<-XML)
<system systemId="http://example.com/a.dtd" uri="two/a.dtd"/>
<system systemId="http://example.com/b.dtd" uri="two/b.dtd"/>
        XML
        resolver = REXML::XMLCatalog::Resolver.new
        resolver.add_catalog(one, uri: "app:///one.xml")
        resolver.add_catalog(two, uri: "app:///two.xml")
        assert_equal("app:///one/a.dtd",
                     resolver.resolve(system_id: "http://example.com/a.dtd").uri)
        assert_equal("app:///two/b.dtd",
                     resolver.resolve(system_id: "http://example.com/b.dtd").uri)
      end
    end

    class TestCircularDelegate < self
      def test_delegate_cycle_reports_chain
        catalogs = {
          "app:///a.xml" =>
            catalog("<delegateSystem systemIdStartString='http://example.com/' catalog='b.xml'/>"),
          "app:///b.xml" =>
            catalog("<delegateSystem systemIdStartString='http://example.com/' catalog='a.xml'/>"),
        }
        resolver = resolver_with(catalogs["app:///a.xml"], uri: "app:///a.xml",
                                 loader: ->(uri) { catalogs[uri] })
        error = assert_raise(REXML::XMLCatalog::CircularDelegateError) do
          resolver.resolve(system_id: "http://example.com/x.dtd")
        end
        assert_equal(["app:///a.xml", "app:///b.xml", "app:///a.xml"],
                     error.catalog_chain)
        assert_include(error.message,
                       "app:///a.xml -> app:///b.xml -> app:///a.xml")
      end

      def test_next_catalog_cycle_reports_chain
        catalogs = {
          "app:///a.xml" => catalog("<nextCatalog catalog='b.xml'/>"),
          "app:///b.xml" => catalog("<nextCatalog catalog='a.xml'/>"),
        }
        resolver = resolver_with(catalogs["app:///a.xml"], uri: "app:///a.xml",
                                 loader: ->(uri) { catalogs[uri] })
        error = assert_raise(REXML::XMLCatalog::CircularDelegateError) do
          resolver.resolve(system_id: "http://example.com/x.dtd")
        end
        assert_equal(["app:///a.xml", "app:///b.xml", "app:///a.xml"],
                     error.catalog_chain)
      end

      def test_self_delegate_cycle
        xml = catalog(<<-XML)
<delegateSystem systemIdStartString="http://example.com/" catalog="a.xml"/>
        XML
        resolver = resolver_with(xml, uri: "app:///a.xml",
                                 loader: ->(uri) { nil })
        error = assert_raise(REXML::XMLCatalog::CircularDelegateError) do
          resolver.resolve(system_id: "http://example.com/x.dtd")
        end
        assert_equal(["app:///a.xml", "app:///a.xml"], error.catalog_chain)
      end
    end

    class TestBaseURI < self
      def test_relative_uri_resolved_against_catalog_uri
        xml = catalog("<system systemId='a' uri='dtd/a.dtd'/>")
        resolver = resolver_with(xml, uri: "file:///opt/mirror/catalog.xml")
        assert_equal("file:///opt/mirror/dtd/a.dtd",
                     resolver.resolve(system_id: "a").uri)
      end

      def test_xml_base_on_catalog
        xml = catalog("<system systemId='a' uri='a.dtd'/>", xml_base: "mirror/")
        resolver = resolver_with(xml, uri: "file:///opt/cat/catalog.xml")
        assert_equal("file:///opt/cat/mirror/a.dtd",
                     resolver.resolve(system_id: "a").uri)
      end

      def test_xml_base_on_group_and_entry
        xml = catalog(<<-XML, xml_base: "mirror/")
<group xml:base="dtd/">
  <system systemId="b" uri="b.dtd"/>
  <system xml:base="../local/" systemId="c" uri="c.dtd"/>
</group>
        XML
        resolver = resolver_with(xml, uri: "file:///opt/cat/catalog.xml")
        assert_equal("file:///opt/cat/mirror/dtd/b.dtd",
                     resolver.resolve(system_id: "b").uri)
        assert_equal("file:///opt/cat/mirror/local/c.dtd",
                     resolver.resolve(system_id: "c").uri)
      end

      def test_delegate_catalog_reference_resolved_against_base
        xml = catalog(<<-XML, xml_base: "base/")
<delegateSystem systemIdStartString="http://example.com/" catalog="sub/c.xml"/>
        XML
        loaded = []
        resolver = resolver_with(xml, uri: "file:///opt/cat/catalog.xml",
                                 loader: ->(uri) { loaded << uri; nil })
        resolver.resolve(system_id: "http://example.com/x.dtd")
        assert_equal(["file:///opt/cat/base/sub/c.xml"], loaded)
      end

      def test_relative_result_kept_when_catalog_has_no_uri
        xml = catalog("<system systemId='a' uri='dtd/a.dtd'/>")
        resolver = resolver_with(xml)
        assert_equal("dtd/a.dtd", resolver.resolve(system_id: "a").uri)
      end
    end

    class TestPolicy < self
      def test_catalog_only_returns_a_plan
        xml = catalog(<<-XML)
<rewriteSystem systemIdStartString="http://legacy.example/" rewritePrefix="file:///etc/"/>
        XML
        resolver = resolver_with(xml, uri: "app:///catalog.xml")
        plan = resolver.resolve(system_id: "http://legacy.example/passwd")
        assert_equal("file:///etc/passwd", plan.uri)
        # The resolver only produced a plan; the caller's policy is
        # what keeps the forbidden resource from being read.
        policy = ->(uri) { uri.start_with?("app:///") }
        fetched = []
        fetched << plan.uri if policy.call(plan.uri)
        assert_equal([], fetched)
      end

      def test_delegate_to_forbidden_catalog_is_denied_by_loader
        xml = catalog(<<-XML)
<delegateSystem systemIdStartString="http://legacy.example/" catalog="file:///etc/secret-catalog.xml"/>
        XML
        requested = []
        resolver = resolver_with(xml, uri: "app:///catalog.xml",
                                 loader: ->(uri) { requested << uri; nil })
        assert_nil(resolver.resolve(system_id: "http://legacy.example/a.dtd"))
        assert_equal(["file:///etc/secret-catalog.xml"], requested)
      end

      def test_rexml_default_external_resource_policy_is_unchanged
        document = REXML::Document.new(<<-XML)
<!DOCTYPE root SYSTEM "file:///etc/passwd">
<root/>
        XML
        assert_equal("file:///etc/passwd", document.doctype.system)
        assert_nil(document.doctype.resolve_external_id(
                     REXML::XMLCatalog::Resolver.new))
      end
    end

    class TestREXMLIntegration < self
      def test_doctype_resolve_external_id_with_public
        document = REXML::Document.new(<<-XML)
<!DOCTYPE root PUBLIC "-//EX//DTD root//EN" "http://example.com/root.dtd">
<root/>
        XML
        xml = catalog(<<-XML)
<public publicId="-//EX//DTD root//EN" uri="mirror/root.dtd"/>
        XML
        plan = document.doctype.resolve_external_id(resolver_with(xml))
        assert_equal("mirror/root.dtd", plan.uri)
        assert_equal(:public, plan.match)
      end

      def test_doctype_resolve_external_id_with_system
        document = REXML::Document.new(<<-XML)
<!DOCTYPE root SYSTEM "http://example.com/root.dtd">
<root/>
        XML
        xml = catalog(<<-XML)
<system systemId="http://example.com/root.dtd" uri="mirror/root.dtd"/>
        XML
        plan = document.doctype.resolve_external_id(resolver_with(xml))
        assert_equal("mirror/root.dtd", plan.uri)
      end

      def test_doctype_without_external_id
        document = REXML::Document.new("<!DOCTYPE root><root/>")
        assert_nil(document.doctype.resolve_external_id(
                     resolver_with(catalog(""))))
      end

      def test_entity_resolve_external_id
        document = REXML::Document.new(<<-XML)
<!DOCTYPE root [
  <!ENTITY ext SYSTEM "http://example.com/ext.ent">
  <!ENTITY int "value">
]>
<root/>
        XML
        xml = catalog(<<-XML)
<system systemId="http://example.com/ext.ent" uri="mirror/ext.ent"/>
        XML
        resolver = resolver_with(xml)
        entities = document.doctype.entities
        plan = entities["ext"].resolve_external_id(resolver)
        assert_equal("mirror/ext.ent", plan.uri)
        assert_nil(entities["int"].resolve_external_id(resolver))
      end
    end

    class TestParseError < self
      def test_non_catalog_document
        assert_raise(REXML::XMLCatalog::ParseError) do
          REXML::XMLCatalog::Resolver.new.add_catalog("<notacatalog/>")
        end
      end

      def test_malformed_document
        assert_raise(REXML::XMLCatalog::ParseError) do
          REXML::XMLCatalog::Resolver.new.add_catalog("<catalog")
        end
      end

      def test_foreign_namespace_is_not_a_catalog
        assert_raise(REXML::XMLCatalog::ParseError) do
          REXML::XMLCatalog::Resolver.new.add_catalog(
            "<catalog xmlns='http://example.com/other'/>")
        end
      end
    end
  end
end
