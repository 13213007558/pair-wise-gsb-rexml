# frozen_string_literal: false

require "stringio"

require "rexml/document"
require "rexml/stream_query"
require "rexml/xpath"

module REXMLTests
  class StreamQueryTest < Test::Unit::TestCase
    # An IO that only returns +chunk_size+ bytes per read call, to prove
    # that streaming queries do not depend on how the input is chunked.
    class ChunkedIO < StringIO
      def initialize(string, chunk_size)
        super(string)
        @chunk_size = chunk_size
      end

      def read(length = nil, outbuf = nil)
        length = @chunk_size if length.nil? or length > @chunk_size
        super(length, outbuf)
      end
    end

    private

    def stream_collect(expression, source, namespaces: nil)
      matches = []
      query = REXML::StreamQuery.new(expression, namespaces: namespaces)
      query.each(source) do |match|
        matches << [match.expanded_name, match.namespace, match.attributes]
      end
      matches
    end

    def dom_collect(expression, xml, namespaces: {})
      matches = []
      document = REXML::Document.new(xml)
      REXML::XPath.each(document, expression, namespaces) do |element|
        attributes = {}
        element.attributes.each_attribute do |attribute|
          attributes[attribute.expanded_name] = attribute.value
        end
        namespace = element.namespace
        namespace = nil if namespace.nil? or namespace.empty?
        matches << [element.expanded_name, namespace, attributes]
      end
      matches
    end

    def assert_same_as_dom(expression, xml, namespaces: {})
      expected = dom_collect(expression, xml, namespaces: namespaces)
      actual = stream_collect(expression, xml, namespaces: namespaces)
      assert_equal(expected, actual,
                   "stream result differs from DOM for #{expression.inspect}")
      actual
    end

    public

    def test_child_path
      xml = "<root><item id='1'/><item id='2'><item id='3'/></item></root>"
      assert_same_as_dom("/root/item", xml)
    end

    def test_relative_path_is_document_rooted
      xml = "<root><item/></root>"
      assert_same_as_dom("root/item", xml)
    end

    def test_descendant
      xml = "<root><a><b><item/></b></a><item/></root>"
      assert_same_as_dom("//item", xml)
    end

    def test_mixed_child_and_descendant
      xml = "<root><a><item><sub/></item></a><b><item><sub/></item></b></root>"
      assert_same_as_dom("/root//item/sub", xml)
    end

    def test_wildcard
      xml = "<root><a/><b/></root>"
      assert_same_as_dom("/root/*", xml)
    end

    def test_attribute_equality
      xml = "<root>" +            "<item id='1' kind='x'/>" +            "<item id='2' kind='y'/>" +            "<item id='3' kind='x'/>" +            "</root>"
      assert_same_as_dom("//item[@kind='x']", xml)
      assert_same_as_dom('//item[@kind="y"]', xml)
      assert_same_as_dom("//item[@kind='x'][@id='3']", xml)
      assert_same_as_dom("//item[@kind='missing']", xml)
    end

    def test_attribute_equality_on_intermediate_step
      xml = "<root>" +            "<group kind='a'><item/></group>" +            "<group kind='b'><item/></group>" +            "</root>"
      assert_same_as_dom("/root/group[@kind='b']/item", xml)
    end

    def test_position
      xml = "<root>" +            "<a><item id='1'/><item id='2'/></a>" +            "<a><item id='3'/></a>" +            "<a><item id='4'/><item id='5'/><item id='6'/></a>" +            "</root>"
      assert_same_as_dom("//item[1]", xml)
      assert_same_as_dom("//item[2]", xml)
      assert_same_as_dom("//item[3]", xml)
      assert_same_as_dom("/root/a[2]/item", xml)
    end

    def test_position_with_attribute_predicate
      xml = "<root>" +            "<item kind='x' id='1'/><item kind='y' id='2'/>" +            "<item kind='x' id='3'/><item kind='x' id='4'/>" +            "</root>"
      assert_same_as_dom("//item[@kind='x'][2]", xml)
    end

    def test_last
      xml = "<root>" +            "<a><item id='1'/><item id='2'/></a>" +            "<a><item id='3'/></a>" +            "<a></a>" +            "</root>"
      assert_same_as_dom("//item[last()]", xml)
      assert_same_as_dom("/root/a[last()]", xml)
      assert_same_as_dom("//a/item[last()]", xml)
    end

    def test_last_with_attribute_predicate
      xml = "<root>" +            "<item kind='x' id='1'/><item kind='y' id='2'/>" +            "<item kind='x' id='3'/>" +            "</root>"
      assert_same_as_dom("//item[@kind='x'][last()]", xml)
    end

    def test_last_results_stay_in_document_order_with_nested_contexts
      # The last item of the outer group appears before the inner group in
      # the document, but the outer group closes after the inner one.  The
      # outer result must still be reported first.
      xml = "<root>" +            "<group><item id='outer'/><group><item id='inner'/></group></group>" +            "</root>"
      matches = assert_same_as_dom("//group/item[last()]", xml)
      assert_equal([["item", nil, {"id" => "outer"}],
                    ["item", nil, {"id" => "inner"}]],
                   matches)
    end

    def test_nested_matches_are_not_duplicated
      xml = "<root><a id='1'><a id='2'><a id='3'/></a></a></root>"
      assert_same_as_dom("//a//a", xml)
      assert_same_as_dom("//a//a//a", xml)
    end

    def test_empty_elements
      xml = "<root><item/><item id='2'></item><item/></root>"
      assert_same_as_dom("//item", xml)
      assert_same_as_dom("//item[last()]", xml)
      assert_same_as_dom("//item[2]", xml)
    end

    def test_namespaces
      xml = "<root xmlns:x='urn:a' xmlns:y='urn:b'>" +            "<x:item x:id='1'/>" +            "<y:item x:id='2'/>" +            "<item x:id='3'/>" +            "</root>"
      namespaces = {"x" => "urn:a", "y" => "urn:b"}
      assert_same_as_dom("//x:item", xml, namespaces: namespaces)
      assert_same_as_dom("//y:item", xml, namespaces: namespaces)
      assert_same_as_dom("/root/x:item", xml, namespaces: namespaces)
      # An unprefixed name test only matches elements without a namespace.
      assert_same_as_dom("//item", xml, namespaces: namespaces)
    end

    def test_namespaced_attribute_predicate
      xml = "<root xmlns:x='urn:a' xmlns:z='urn:a'>" +            "<item x:id='1'/>" +            "<item z:id='1'/>" +            "<item id='1'/>" +            "</root>"
      namespaces = {"x" => "urn:a"}
      assert_same_as_dom("//item[@x:id='1']", xml, namespaces: namespaces)
      assert_same_as_dom("//item[@id='1']", xml, namespaces: namespaces)
    end

    def test_default_namespace_does_not_match_unprefixed_test
      xml = "<root xmlns='urn:default'><item id='1'/></root>"
      assert_same_as_dom("//item", xml, namespaces: {})
    end

    def test_chunked_input_matches_dom
      xml = "<root xmlns:x='urn:a'>" +            "<a><x:item id='1'/><item id='2'/></a>" +            "<a><item id='3'><sub/></item><item id='4'/></a>" +            "<a/>" +            "</root>"
      ["//item", "//item[2]", "//item[last()]", "/root/a/item[@id='3']/sub",
       "//x:item"].each do |expression|
        namespaces = {"x" => "urn:a"}
        expected = dom_collect(expression, xml, namespaces: namespaces)
        [1, 3, 7, 64].each do |chunk_size|
          actual = stream_collect(expression, ChunkedIO.new(xml, chunk_size),
                                  namespaces: namespaces)
          assert_equal(expected, actual,
                       "chunk size #{chunk_size} differs for #{expression.inspect}")
        end
      end
    end

    def test_results_are_in_document_order
      xml = "<root>" +            "<a><item id='1'/></a>" +            "<item id='2'/>" +            "<b><c><item id='3'/></c></b>" +            "<item id='4'/>" +            "</root>"
      matches = assert_same_as_dom("//item", xml)
      assert_equal(%w[1 2 3 4], matches.map {|_, _, attrs| attrs["id"]})
    end

    def test_early_break_releases_state_and_stops_reading
      xml = "<root>" + ("<item/>" * 100) + "</root>"
      source = ChunkedIO.new(xml, 16)
      query = REXML::StreamQuery.new("//item")
      seen = 0
      query.each(source) do |_match|
        seen += 1
        break if seen == 2
      end
      assert_equal(2, seen)
      assert_operator(source.pos, :<, xml.bytesize,
                      "the whole document was consumed despite early break")
      # The query instance is reusable after an abandoned run.
      assert_equal(100, query.each(xml).count)
    end

    def test_early_break_with_last
      xml = "<root><a><item id='1'/></a><a><item id='2'/></a></root>"
      source = ChunkedIO.new(xml, 8)
      query = REXML::StreamQuery.new("//item[last()]")
      matches = []
      query.each(source) do |match|
        matches << match
        break
      end
      assert_equal(1, matches.size)
      assert_equal("1", matches[0].attributes["id"])
      assert_equal(2, query.each(xml).count)
    end

    def test_enumerator_without_block
      xml = "<root><item id='1'/><item id='2'/><item id='3'/></root>"
      query = REXML::StreamQuery.new("//item")
      enum = query.each(xml)
      ids = []
      3.times {ids << enum.next.attributes["id"]}
      assert_equal(%w[1 2 3], ids)
      assert_raise(StopIteration) {enum.next}
    end

    def test_match_accessors
      xml = "<root xmlns:x='urn:a'><x:item x:id='7' kind='book'/></root>"
      match = nil
      REXML::StreamQuery.new("//x:item", namespaces: {"x" => "urn:a"}).
        each(xml) {|m| match = m}
      assert_equal("item", match.name)
      assert_equal("x", match.prefix)
      assert_equal("x:item", match.expanded_name)
      assert_equal("urn:a", match.namespace)
      assert_equal("7", match.attributes["x:id"])
      assert_equal("book", match.attributes["kind"])
      assert_equal(2, match.depth)
    end

    def test_unsupported_expressions_are_rejected_upfront
      unsupported = [
        "//a/b[@x]",              # attribute existence
        "//a[text()='x']",        # text comparison
        "//a[position()=2]",      # function other than last()
        "//a[contains(@x, 'y')]",
        "//a | //b",              # union
        "//a/..",                 # parent axis
        "//a/@id",                # attribute step
        "//a[2][@x='1']",         # position predicate not last
        "//a[1][2]",              # two position predicates
        "/a/b[last()]/c",         # last() on a non-final step
        "//a[0]",                 # positions start at 1
        "child::a",               # explicit axes are not supported
        "descendant::a",
        "//a/b[",                 # syntax errors
        "//a/",
        "",
        nil,
        "//a[x='1']",             # only attribute equality is supported
      ]
      unsupported.each do |expression|
        assert_raise(REXML::ParseException,
                     "expected #{expression.inspect} to be rejected") do
          REXML::StreamQuery.new(expression)
        end
      end
    end

    def test_undefined_namespace_prefix_is_rejected_upfront
      assert_raise(REXML::ParseException) do
        REXML::StreamQuery.new("//x:item")
      end
      assert_raise(REXML::ParseException) do
        REXML::StreamQuery.new("//item[@x:id='1']")
      end
    end

    def test_parse_errors_propagate
      query = REXML::StreamQuery.new("//item")
      assert_raise(REXML::ParseException) do
        query.each("<root><item></root>") {|_|}
      end
    end

    def test_class_level_each
      xml = "<root><item id='1'/></root>"
      matches = []
      REXML::StreamQuery.each(xml, "//item") {|match| matches << match}
      assert_equal(1, matches.size)
    end

    def test_text_and_comments_between_elements
      xml = "<root>text<a>more<!-- comment --><item id='1'/>tail</a>" +            "<![CDATA[ignored]]><item id='2'/></root>"
      assert_same_as_dom("//item", xml)
      assert_same_as_dom("//item[last()]", xml)
    end

    def test_no_dom_is_built
      xml = "<root>" + ("<a><item id='1'/><item id='2'/></a>" * 50) + "</root>"
      query = REXML::StreamQuery.new("//item[last()]")
      GC.start
      before = ObjectSpace.each_object(REXML::Element).count
      assert_equal(50, query.each(xml).count)
      GC.start
      after = ObjectSpace.each_object(REXML::Element).count
      assert_equal(before, after,
                   "streaming query built DOM elements")
    end

    def test_kitchen_sink_against_dom
      xml = "<root xmlns:x='urn:a'>" +            "<a><item id='1'/><x:item id='2'/></a>" +            "<a><item id='3'><item id='4'/></item></a>" +            "<b><item id='5'/><item id='6'/><item id='7'/></b>" +            "<a/>" +            "</root>"
      namespaces = {"x" => "urn:a"}
      ["//item", "/root/a", "//a/item", "//item[1]", "//item[2]",
       "//item[last()]", "//a/item[last()]", "//x:item",
       "//item[@id='5']", "//item[@id='6'][last()]",
       "/root/b/item[3]", "//a//item"].each do |expression|
        assert_same_as_dom(expression, xml, namespaces: namespaces)
      end
    end
  end
end
