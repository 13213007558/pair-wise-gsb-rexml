# frozen_string_literal: false
require_relative "helper"

module REXMLTests
  class RangeTest < Test::Unit::TestCase
    def three_layer_document
      xml = "<root xmlns=\"urn:default\" xmlns:ns=\"urn:ns\" id=\"root-id\"><section>" \
            "<ns:article id=\"article-id\" role=\"post\">AB" \
            "<keep id=\"keep-id\" type=\"complete\">XY</keep>" \
            "<ns:em>CD<![CDATA[EF&am]]>P&amp;QGH</ns:em>Z" \
            "</ns:article>tail</section></root>"
      [REXML::Document.new(xml), xml]
    end

    def nested_range(document)
      article = document.elements["//ns:article"]
      em = document.elements["//ns:em"]
      REXML::Range.new(article.get_text, 1, em.cdatas.first, 4)
    end

    def all_text(element)
      result = +""
      collect_text(element, result)
      result
    end

    def collect_text(node, result)
      node.children.each do |child|
        if child.is_a?(REXML::Text)
          result << child.value
        else
          collect_text(child, result)
        end
      end
    end

    def test_text_uses_logical_character_offsets_across_three_layers
      document, = three_layer_document
      range = nested_range(document)

      assert_equal("BXYCDEF&aZ", range.text)
    end

    def test_extract_copies_partial_shells_and_moves_complete_nodes
      document, = three_layer_document
      article = document.elements["//ns:article"]
      keep = article.elements["keep"]
      range = nested_range(document)

      fragment = range.extract
      assert_equal("BXYCDEF&aZ", range.text)

      assert_equal("<ns:article xmlns:ns='urn:ns' role='post' xmlns='urn:default'>" \
                   "B<keep id='keep-id' type='complete'>XY</keep>" \
                   "<ns:em>CD<![CDATA[EF&a]]></ns:em></ns:article>",
                   fragment.to_s)
      assert_equal(keep.object_id, fragment.elements["keep"].object_id)
      assert_nil(fragment.attributes["id"])
      assert_equal("urn:ns", fragment.namespace("ns"))

      expected_remaining = "<root id='root-id' xmlns:ns='urn:ns' xmlns='urn:default'><section>" \
                           "<ns:article id='article-id' role='post'>A" \
                           "<ns:em><![CDATA[m]]>P&amp;QGH</ns:em>Z" \
                           "</ns:article>tail</section></root>"
      assert_equal(expected_remaining, document.root.to_s)
      assert_equal(["root-id", "article-id"], ids_in(document))
      assert_equal(["keep-id"], ids_in(fragment))
    end

    def test_surround_moves_selection_without_extracted_ancestor_shells
      document, = three_layer_document
      original_text = all_text(document.root)
      range = nested_range(document)

      wrapper = range.surround("mark")
      assert_equal("BXYCDEF&aZ", range.text)

      assert_equal("<mark>B<keep id='keep-id' type='complete'>XY</keep>" \
                   "CD<![CDATA[EF&a]]></mark>", wrapper.to_s)
      expected_surrounded = "<root id='root-id' xmlns:ns='urn:ns' xmlns='urn:default'><section>" \
                            "<ns:article id='article-id' role='post'>A" \
                            "<mark>B<keep id='keep-id' type='complete'>XY</keep>" \
                            "CD<![CDATA[EF&a]]></mark>" \
                            "<ns:em><![CDATA[m]]>P&amp;QGH</ns:em>Z" \
                            "</ns:article>tail</section></root>"
      assert_equal(expected_surrounded, document.root.to_s)
      assert_equal(original_text, all_text(document.root))
      assert_equal(["root-id", "article-id", "keep-id"], ids_in(document))
    end

    def test_entity_references_have_atomic_boundaries
      document = REXML::Document.new("<root>a&amp;b&#65;c</root>")
      text = document.root.get_text

      assert_equal("a&bAc", REXML::Range.new(text, 0, text, 5).text)
      assert_equal("&", REXML::Range.new(text, 1, text, 2).text)
      assert_equal("A", REXML::Range.new(text, 3, text, 4).text)
      fragment = REXML::Range.new(text, 1, text, 3).extract
      assert_equal("<root>&amp;b</root>", fragment.to_s)
      assert_equal("<root>a&#65;c</root>", document.root.to_s)

      custom_document = REXML::Document.new("<!DOCTYPE root [<!ENTITY foo 'xy'>]><root>a&foo;b</root>")
      custom_text = custom_document.root.get_text
      [[1, 2], [2, 3]].each do |start_offset, end_offset|
        assert_raise(ArgumentError, "offset #{start_offset}:#{end_offset}") do
          REXML::Range.new(custom_text, start_offset, custom_text, end_offset)
        end
      end
    end

    def test_cdata_references_are_literal_characters
      document = REXML::Document.new("<root><![CDATA[a&amp;b]]></root>")
      cdata = document.root.cdatas.first

      fragment = REXML::Range.new(cdata, 1, cdata, 7).extract

      assert_equal("<root><![CDATA[&amp;b]]></root>", fragment.to_s)
      assert_equal("<root><![CDATA[a]]></root>", document.root.to_s)
    end

    def test_xml_id_is_not_copied_to_a_partial_shell
      document = REXML::Document.new("<root xml:id='root'><b>left</b>right</root>")
      start = document.elements["//b"].get_text
      finish = document.root.get_text

      fragment = REXML::Range.new(start, 2, finish, 2).extract

      assert_nil(fragment.attributes["xml:id"])
      assert_equal("root", document.root.attributes["xml:id"])
    end

    def test_zero_length_surround_inserts_an_empty_wrapper
      document = REXML::Document.new("<root>ab</root>")
      text = document.root.get_text

      REXML::Range.new(text, 1, text, 1).surround("caret")

      assert_equal("<root>a<caret/>b</root>", document.root.to_s)
    end

    def test_surround_starts_at_text_boundary
      document = REXML::Document.new("<root><a>hello <b>brave</b> world</a></root>")
      first_text = document.elements["//a"].get_text
      second_text = document.elements["//b"].get_text

      wrapper = REXML::Range.new(first_text, 0, second_text, 3).surround("mark")

      assert_equal("<mark>hello bra</mark>", wrapper.to_s)
      assert_equal("<root><a><mark>hello bra</mark><b>ve</b> world</a></root>",
                   document.root.to_s)
    end

    def test_extract_starts_at_text_boundary
      document = REXML::Document.new("<root><a>hello <b>brave</b> world</a></root>")
      first_text = document.elements["//a"].get_text
      second_text = document.elements["//b"].get_text

      fragment = REXML::Range.new(first_text, 0, second_text, 3).extract

      assert_equal("<a>hello <b>bra</b></a>", fragment.to_s)
      assert_equal("<root><a><b>ve</b> world</a></root>", document.root.to_s)
    end

    def test_range_can_start_and_end_between_elements
      document = REXML::Document.new("<root><a>abc<b>def</b>ghi</a></root>")
      first_text = document.elements["//a"].get_text
      second_text = document.elements["//b"].get_text

      wrapper = REXML::Range.new(first_text, 3, second_text, 0).surround("m")

      assert_equal("<m/>", wrapper.to_s)
      assert_equal("<root><a>abc<m/><b>def</b>ghi</a></root>", document.root.to_s)
    end

    def test_zero_length_extract_returns_empty_ancestor_shell
      document = REXML::Document.new("<root xmlns:ns='urn:ns'>ab</root>")
      text = document.root.get_text

      fragment = REXML::Range.new(text, 1, text, 1).extract

      assert_equal("<root xmlns:ns='urn:ns'/>", fragment.to_s)
      assert_equal("<root xmlns:ns='urn:ns'>ab</root>", document.root.to_s)
    end

    private

    def ids_in(root)
      ids = []
      collect_ids(root, ids)
      ids
    end

    def collect_ids(element, ids)
      ids << element.attributes["id"] if element.attributes["id"]
      ids << element.attributes["xml:id"] if element.attributes["xml:id"]
      element.each_element do |child|
        collect_ids(child, ids)
      end
    end
  end
end
