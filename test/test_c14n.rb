# frozen_string_literal: false

require_relative "helper"

require "rexml/c14n"
require "rexml/xpath"

module REXMLTests
  class TestC14N < Test::Unit::TestCase
    include Helper::Fixture

    # Official Canonical XML 1.1 test vectors, see
    # test/data/c14n11/README.md for the pinned sources.
    VECTORS = {
      "example-4-1" => {with_comments: true},
      "example-4-2" => {},
      "example-4-3" => {},
      "example-4-4" => {},
      "example-4-5" => {},
      "example-4-6" => {xpath: "//e2"},
      "xmlbase-1" => {xpath: "//b"},
      "xmlbase-2" => {xpath: "//b"},
      "xmlbase-3" => {xpath: "//b"},
      "xmlbase-4" => {xpath: "//b"},
      "xmlbase-5" => {xpath: "//b"},
      "xmlid-1" => {xpath: "//b"},
      "xmlid-2" => {xpath: "//b"},
    }

    VECTORS.each do |name, options|
      define_method("test_vector_#{name}") do
        xpath = options[:xpath]
        with_comments = options.fetch(:with_comments, false)
        document = REXML::Document.new(read_vector(name, ".xml"))
        node = xpath ? REXML::XPath.first(document, xpath) : document
        expected = read_vector(name, ".c14n")
        actual = REXML::C14N.canonicalize(node, with_comments: with_comments)
        assert_equal(expected, actual)
      end
    end

    def read_vector(name, extension)
      # Vector files end with a newline for editor friendliness; it is
      # not part of the expected canonical form.
      File.read(fixture_path("c14n11", "#{name}#{extension}")).delete_suffix("\n")
    end

    def canonicalize(source, **options)
      REXML::C14N.canonicalize(REXML::Document.new(source), **options)
    end

    def test_comments_are_excluded_by_default
      source = "<doc><!-- hidden --><e/></doc>"
      assert_equal("<doc><e></e></doc>", canonicalize(source))
    end

    def test_comments_are_included_with_with_comments
      source = "<doc><!-- shown --><e/></doc>"
      assert_equal("<doc><!-- shown --><e></e></doc>",
                   canonicalize(source, with_comments: true))
    end

    def test_empty_element_gets_separate_end_tag
      assert_equal("<doc><e></e></doc>", canonicalize("<doc><e/></doc>"))
    end

    def test_attributes_are_sorted_by_local_name
      assert_equal(%{<e a="1" b="2" c="3"></e>},
                   canonicalize(%{<e c="3" a="1" b="2"/>}))
    end

    def test_attributes_are_sorted_by_namespace_uri_then_local_name
      source = %{<e xmlns:b="http://b" xmlns:a="http://a" } +
               %{b:x="1" a:z="2" a:y="3" plain="4"/>}
      assert_equal(%{<e xmlns:a="http://a" xmlns:b="http://b" } +
                   %{plain="4" a:y="3" a:z="2" b:x="1"></e>},
                   canonicalize(source))
    end

    def test_namespace_declarations_are_sorted_by_prefix
      source = %{<e xmlns:z="http://z" xmlns="http://default" xmlns:a="http://a"/>}
      assert_equal(%{<e xmlns="http://default" xmlns:a="http://a" xmlns:z="http://z"></e>},
                   canonicalize(source))
    end

    def test_text_is_escaped
      assert_equal("<e>&lt;&gt;&amp;\"'&#xD;</e>",
                   canonicalize("<e>&lt;>&amp;\"'&#xD;</e>"))
    end

    def test_attribute_values_are_escaped
      source = %{<e a="&lt;>&amp;&quot;'&#x9;&#xA;&#xD;"/>}
      assert_equal(%{<e a="&lt;>&amp;&quot;'&#x9;&#xA;&#xD;"></e>},
                   canonicalize(source))
    end

    def test_cdata_is_replaced_by_escaped_character_content
      assert_equal("<e>&lt;tag&gt;&amp;</e>",
                   canonicalize("<e><![CDATA[<tag>&]]></e>"))
    end

    def test_processing_instructions
      assert_equal(%{<doc><?pi data?></doc>},
                   canonicalize(%{<doc><?pi data?></doc>}))
      assert_equal(%{<doc><?pi?></doc>},
                   canonicalize(%{<doc><?pi     ?></doc>}))
    end

    def test_top_level_nodes_are_separated_by_a_line_feed
      source = "<?pi a?>\n\n<doc/>\n\n<!-- c -->\n"
      assert_equal("<?pi a?>\n<doc></doc>\n<!-- c -->",
                   canonicalize(source, with_comments: true))
    end

    def test_output_is_utf_8
      result = canonicalize("<e>\u00e9\u4e2d</e>")
      assert_equal(Encoding::UTF_8, result.encoding)
      assert_equal("<e>\u00e9\u4e2d</e>", result)
    end

    def test_source_tree_is_not_modified
      document = REXML::Document.new(
        %{<doc xml:base="http://example.com/" xml:id="d" } +
        %{xmlns:n="http://n"><a><n:b x="1"/></a></doc>})
      before = document.to_s
      REXML::C14N.canonicalize(document)
      REXML::C14N.canonicalize(REXML::XPath.first(document, "//n:b"),
                               with_comments: true)
      assert_equal(before, document.to_s)
    end

    def test_unsupported_node_type
      assert_raise(ArgumentError) do
        REXML::C14N.canonicalize(REXML::Text.new("text"))
      end
    end
  end

  class TestC14NSubtree < Test::Unit::TestCase
    def canonicalize_element(source, xpath)
      document = REXML::Document.new(source)
      REXML::C14N.canonicalize(REXML::XPath.first(document, xpath))
    end

    def test_subtree_root_inherits_in_scope_namespaces
      source = %{<doc xmlns="http://default" xmlns:n="http://n">} +
               %{<a><b n:x="1"/></a></doc>}
      assert_equal(%{<b xmlns="http://default" xmlns:n="http://n" n:x="1"></b>},
                   canonicalize_element(source, "//b"))
    end

    def test_subtree_root_does_not_render_empty_default_namespace
      source = %{<doc xmlns="http://default"><a xmlns=""><b/></a></doc>}
      assert_equal(%{<b></b>}, canonicalize_element(source, "//b"))
    end

    def test_subtree_root_with_own_namespaces
      source = %{<doc xmlns:n="http://n"><a xmlns:n="http://other">} +
               %{<b xmlns:m="http://m"/></a></doc>}
      assert_equal(%{<b xmlns:m="http://m" xmlns:n="http://other"></b>},
                   canonicalize_element(source, "//b"))
    end

    def test_subtree_inherits_xml_lang_and_xml_space
      source = %{<doc xml:lang="en" xml:space="preserve">} +
               %{<a xml:lang="fr"><b/></a></doc>}
      assert_equal(%{<b xml:lang="fr" xml:space="preserve"></b>},
                   canonicalize_element(source, "//b"))
    end

    def test_subtree_xml_attributes_of_root_win
      source = %{<doc xml:lang="en"><a><b xml:lang="de"/></a></doc>}
      assert_equal(%{<b xml:lang="de"></b>},
                   canonicalize_element(source, "//b"))
    end

    def test_subtree_inherits_nearest_xml_id
      source = %{<doc xml:id="d"><a xml:id="a"><b/></a></doc>}
      assert_equal(%{<b xml:id="a"></b>},
                   canonicalize_element(source, "//b"))
    end

    def test_subtree_inherits_xml_base
      source = %{<doc xml:base="http://example.com/dir/">} +
               %{<a><b/></a></doc>}
      assert_equal(%{<b xml:base="http://example.com/dir/"></b>},
                   canonicalize_element(source, "//b"))
    end

    def test_subtree_xml_base_is_joined
      source = %{<doc xml:base="http://example.com/">} +
               %{<a xml:base="dir/"><b xml:base="file"/></a></doc>}
      assert_equal(%{<b xml:base="http://example.com/dir/file"></b>},
                   canonicalize_element(source, "//b"))
    end

    def test_subtree_absolute_xml_base_wins
      source = %{<doc xml:base="http://example.com/">} +
               %{<a><b xml:base="http://other.example/x"/></a></doc>}
      assert_equal(%{<b xml:base="http://other.example/x"></b>},
                   canonicalize_element(source, "//b"))
    end

    def test_subtree_same_document_xml_base_is_concatenated
      source = %{<doc xml:base="http://example.com/doc">} +
               %{<a xml:base="#one"><b xml:base="#two"/></a></doc>}
      assert_equal(%{<b xml:base="http://example.com/doc#one#two"></b>},
                   canonicalize_element(source, "//b"))
    end

    def test_subtree_xml_base_dot_segments_are_resolved
      source = %{<doc xml:base="http://example.com/a/b/c">} +
               %{<a xml:base="../d"><b/></a></doc>}
      assert_equal(%{<b xml:base="http://example.com/a/d"></b>},
                   canonicalize_element(source, "//b"))
    end

    def test_subtree_comments_are_optional
      source = %{<doc><a><b><!-- c --></b></a></doc>}
      element = REXML::XPath.first(REXML::Document.new(source), "//b")
      assert_equal("<b></b>", REXML::C14N.canonicalize(element))
      assert_equal("<b><!-- c --></b>",
                   REXML::C14N.canonicalize(element, with_comments: true))
    end
  end
end
