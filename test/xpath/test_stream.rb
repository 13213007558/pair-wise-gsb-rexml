# frozen_string_literal: false
require "test/unit"
require "stringio"
require "rexml/document"

module REXMLTests
  class TestXPathStream < Test::Unit::TestCase
    XML = <<~XML
      <root xmlns:n="urn:n">
        <item id="1" n:kind="first">
          <child id="one">one</child>
        </item>
        <item id="2">
            <child id="two">two</child>
          <n:child>three</n:child>
        </item>
        <item id="3" n:kind="third">
          <empty/>
          <group>
            <child id="four">four</child>
          </group>
          <child id="five">five</child>
        </item>
      </root>
    XML

    SUPPORTED = [
      "/root",
      "root",
      "/root/item",
      "//item",
      "//child",
      "descendant::child",
      "root/item/child",
      "root//child",
      "item/*",
      "//*",
      "n:child",
      "//n:child",
      "//n:*",
      "//*:child",
      "item[@id]",
      "item[@id='2']",
      "item[@id!='2']",
      "item[1]",
      "item[position()=2]",
      "item[position()>=2]",
      "item[last()]",
      "item[last()-1]",
      "item[position()<last()]",
      "item[@id='1' and @n:kind='first']",
      "item[@n:kind][1]"
    ].freeze

    UNSUPPORTED = [
      ".",
      "..",
      "text()",
      "@id",
      "a/text()",
      "a | b",
      "ancestor::a",
      "a[contains(@id, 'x')]",
      "a[@id<'1']",
      "a[@id or @name]",
      "a[last()]/b",
      "a[$count]"
    ].freeze

    def test_supported_subset_is_compiled
      SUPPORTED.each do |expression|
        assert_nothing_raised(expression) do
          REXML::XPath::Stream.new(expression, namespaces)
        end
      end
    end

    def test_unsupported_expressions_are_rejected_before_parsing
      read_after_rejection = true
      source = Object.new
      source.define_singleton_method(:read) { read_after_rejection = false }
      source.define_singleton_method(:readline) { raise IOError }
      source.define_singleton_method(:eof?) { false }
      source.define_singleton_method(:nil?) { false }

      UNSUPPORTED.each do |expression|
        assert_raise(REXML::ParseException, expression) do
          REXML::XPath.each_stream(source, expression, namespaces) { }
        end
        assert(read_after_rejection, expression)
      end
    end

    def test_namespaces_must_be_a_hash
      assert_raise(ArgumentError) do
        REXML::XPath.each_stream("<r/>", "r", []) { }
      end
    end

    def test_stream_matches_dom
      [
        "//n:child",
        "item[@n:kind][1]",
        "item[@n:kind][last()]",
        "item/child",
        "item//child",
        "//child[1]",
        "//child[last()]",
        "/root/item[@id='3']//child[last()]",
        "item[@id='3']//child",
        "item[position()=2]/child",
        "item[last()-1]"
      ].each do |expression|
        assert_equal(dom_elements(expression), stream_elements(expression, XML),
                     expression)
      end
    end

    def test_default_namespace_does_not_match_unprefixed_names
      xml = '<root xmlns="urn:default"><item/></root>'
      assert_equal([], stream_elements("//item", xml))
      assert_equal([["item", "urn:default"]],
                   stream_elements("//d:item", xml))
    end

    def test_empty_element
      assert_equal([["empty", ""]],
                   stream_elements("//empty", XML))
    end

    def test_nested_matches_are_in_document_order
      values = []
      REXML::XPath.each_stream(XML, "//child", namespaces) do |element|
        values << element["id"]
      end
      assert_equal(%w[one two four five], values)
    end

    def test_chunked_io
      [1, 2, 3, 7, 19].each do |chunk_size|
        source = ChunkIO.new(XML, chunk_size)
        values = []
        REXML::XPath.each_stream(source,
                                 "/root/item[@id='3']//child",
                                 namespaces) do |element|
          values << element.name
        end
        assert_equal(%w[child child], values, chunk_size.to_s)
      end
    end

    def test_early_stop_releases_state
      source = CountingIO.new(
        "<root>" + ("<item><child/></item>" * 20) + "</root>"
      )
      query = REXML::XPath::Stream.new("//child")
      catch(:stop) do
        query.parse(source) do
          throw(:stop)
        end
      end
      assert_operator(source.reads, :>, 0)
      reads_after_stop = source.reads
      assert_equal(0, query.active_frames)
      assert_equal(reads_after_stop, source.reads)
    end

    private
    def namespaces
      {"n" => "urn:n", "d" => "urn:default"}
    end

    def dom_elements(expression, xml=XML)
      document = REXML::Document.new(xml)
      REXML::XPath.match(document, expression, namespaces).map do |element|
        [element.local_name, element.namespace]
      end
    end

    def stream_elements(expression, xml=XML)
      values = []
      REXML::XPath.each_stream(xml, expression, namespaces) do |element|
        values << [element.local_name, element.namespace]
      end
      values
    end

    class ChunkIO
      def initialize(xml, chunk_size)
        @io = StringIO.new(xml.dup)
        @chunk_size = chunk_size
      end

      def read(*)
        @io.read(@chunk_size)
      end

      def readline(*)
        @io.readline(*)
      end

      def eof?
        @io.eof?
      end

      def pos
        @io.pos
      end

      def lineno
        @io.lineno
      end

      def rewind
        @io.rewind
      end

      def seek(*arguments)
        @io.seek(*arguments)
      end

      def nil?
        false
      end
    end

    class CountingIO < ChunkIO
      attr_reader :reads

      def initialize(xml)
        super(xml, 1)
        @reads = 0
      end

      def read(*arguments)
        @reads += 1
        super(*arguments)
      end
    end
  end
end
