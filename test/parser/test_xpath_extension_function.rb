# frozen_string_literal: false

require "rexml/parsers/xpathparser"

module REXMLTests
  class TestParserXPathExtensionFunction < Test::Unit::TestCase
    def test_prefixed_function_name
      parser = REXML::Parsers::XPathParser.new

      assert_equal([:function, [:qname, "service", "value"], []],
                   parser.parse("service:value()"))
    end
  end
end
