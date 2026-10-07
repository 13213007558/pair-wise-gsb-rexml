# frozen_string_literal: true

require_relative "helper"
require "rexml/xslt"

module REXML
  module Tests
    class TestXSLT < Test::Unit::TestCase
      def transform(stylesheet, source, parameters = {}, resources = nil)
        resources ||= {"main.xsl" => stylesheet}
        XSLT::Processor.new("main.xsl", resources, parameters).transform(source)
      end

      def basic_stylesheet
        <<~XSL
          <xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
                          xmlns:e="https://example.test/ns" version="1.0">
            <xsl:template match="/">
              <root>
                <xsl:apply-templates select="items/item"/>
              </root>
            </xsl:template>
            <xsl:template match="item">
              <value><xsl:value-of select="."/></value>
            </xsl:template>
          </xsl:stylesheet>
        XSL
      end

      def test_literal_result_element_apply_templates_and_value_of
        result = transform(basic_stylesheet, "<items><item>one</item><item>two</item></items>")
        assert_equal("<root><value>one</value><value>two</value></root>", result.to_s)
        assert_equal(%w[/ /items/item /items/item], result.selections.collect { |selection| selection[:node] })
      end

      def test_document_order_tie_uses_last_template
        stylesheet = <<~XSL
          <xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
                          xmlns:e="https://example.test/ns" version="1.0">
            <xsl:template match="item"><first><xsl:value-of select="."/></first></xsl:template>
            <xsl:template match="item"><last><xsl:value-of select="."/></last></xsl:template>
            <xsl:template match="/">
              <root><xsl:apply-templates select="items/item"/></root>
            </xsl:template>
          </xsl:stylesheet>
        XSL
        result = transform(stylesheet, "<items><item>x</item></items>")
        assert_equal("<root><last>x</last></root>", result.to_s)
        selection = result.selections.last
        assert_equal(0.0, selection[:priority])
        assert_equal("default priority", selection[:priority_source])
        assert_match("declaration order tie", selection[:basis])
        assert_equal(2, selection[:considered].size)
      end

      def test_explicit_priority_beats_document_order_tie
        stylesheet = <<~XSL
          <xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
            <xsl:template match="item"><low><xsl:value-of select="."/></low></xsl:template>
            <xsl:template match="item" priority="2"><high><xsl:value-of select="."/></high></xsl:template>
            <xsl:template match="item" priority="1.5"><high><xsl:value-of select="."/></high></xsl:template>
            <xsl:template match="item" priority="2.5"><winner><xsl:value-of select="."/></winner></xsl:template>
            <xsl:template match="/">
              <root><xsl:apply-templates select="items/item"/></root>
            </xsl:template>
          </xsl:stylesheet>
        XSL
        result = transform(stylesheet, "<items><item>x</item></items>")
        assert_equal("<root><winner>x</winner></root>", result.to_s)
        assert_equal(2.5, result.selections.last[:priority])
        assert_equal("explicit priority=2.5", result.selections.last[:priority_source])
      end

      def test_default_priorities_for_overlapping_patterns
        stylesheet = <<~XSL
          <xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
            <xsl:template match="*" priority="-1"><star/></xsl:template>
            <xsl:template match="group/item"><path><xsl:value-of select="."/></path></xsl:template>
            <xsl:template match="item[@kind='special']"><special><xsl:value-of select="."/></special></xsl:template>
            <xsl:template match="item"><plain><xsl:value-of select="."/></plain></xsl:template>
            <xsl:template match="/">
              <root><xsl:apply-templates select="group/item"/></root>
            </xsl:template>
          </xsl:stylesheet>
        XSL
        source = "<group><item kind='special'>s</item><item>p</item></group>"
        result = transform(stylesheet, source)
        assert_equal("<root><special>s</special><path>p</path></root>", result.to_s)
        special, plain = result.selections[1], result.selections[2]
        assert_equal(0.5, special[:priority])
        assert_equal(0.5, plain[:priority])
      end

      def test_relative_descendant_pattern
        stylesheet = <<~XSL
          <xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
            <xsl:template match="/"><out><xsl:apply-templates select="root"/></out></xsl:template>
            <xsl:template match="//item"><i><xsl:value-of select="."/></i></xsl:template>
          </xsl:stylesheet>
        XSL
        result = transform(stylesheet, "<root><section><item>deep</item></section></root>")
        assert_equal("<out><i>deep</i></out>", result.to_s)
      end

      def test_pattern_default_priorities
        stylesheet_namespaces = {"n" => "https://example.test/ns"}
        cases = {
          "item" => 0.0,
          "*" => -0.5,
          "n:*" => -0.25,
          "text()" => -0.5,
          "group/item" => 0.5,
          "//item" => 0.5,
          "item[@kind='x']" => 0.5,
          "a|b" => 0.0,
          "a|*" => 0.5
        }
        cases.each do |pattern, priority|
          parsed = XSLT::Pattern.parse(pattern, stylesheet_namespaces)
          assert_equal(priority, parsed.default_priority, pattern)
        end
      end

      def test_namespaced_pattern_from_imported_stylesheet
        imported = <<~XSL
          <xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
                          xmlns:e="https://example.test/ns" version="1.0">
            <xsl:template match="e:item"><matched><xsl:value-of select="."/></matched></xsl:template>
          </xsl:stylesheet>
        XSL
        main = <<~XSL
          <xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
                          xmlns:e="https://example.test/ns" version="1.0">
            <xsl:import href="imported.xsl"/>
            <xsl:template match="/">
              <out xmlns:e="https://example.test/ns">
                <xsl:apply-templates select="e:root/e:item"/>
              </out>
            </xsl:template>
          </xsl:stylesheet>
        XSL
        source = "<e:root xmlns:e='https://example.test/ns'><e:item>namespaced</e:item></e:root>"
        resources = {"main.xsl" => main, "imported.xsl" => imported}
        result = transform(main, source, {}, resources)
        assert_equal("<out xmlns:e='https://example.test/ns'><matched>namespaced</matched></out>", result.to_s)
      end

      def test_import_precedence_beats_priority_and_document_order
        imported = <<~XSL
          <xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
            <xsl:template match="item" priority="9">
              <imported><xsl:value-of select="."/></imported>
            </xsl:template>
          </xsl:stylesheet>
        XSL
        main = <<~XSL
          <xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
            <xsl:import href="lib/common.xsl"/>
            <xsl:template match="item"><main><xsl:value-of select="."/></main></xsl:template>
            <xsl:template match="/">
              <root><xsl:apply-templates select="items/item"/></root>
            </xsl:template>
          </xsl:stylesheet>
        XSL
        resources = {"main.xsl" => main, "lib/common.xsl" => imported}
        result = transform(main, "<items><item>x</item></items>", {}, resources)
        assert_equal("<root><main>x</main></root>", result.to_s)
        assert_match("highest import precedence", result.selections.last[:basis])
      end

      def test_modes_and_call_template_parameters
        stylesheet = <<~XSL
          <xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
            <xsl:param name="prefix">P</xsl:param>
            <xsl:template match="/">
              <root>
                <xsl:apply-templates select="items/item" mode="label">
                  <xsl:with-param name="suffix" select='&quot;-S&quot;'/>
                </xsl:apply-templates>
              </root>
            </xsl:template>
            <xsl:template match="item">
              <default><xsl:value-of select="."/></default>
            </xsl:template>
            <xsl:template match="item" mode="label">
              <xsl:param name="suffix" select='&quot;-D&quot;'/>
              <xsl:call-template name="labelled">
                <xsl:with-param name="text" select="."/>
                <xsl:with-param name="ending" select="$suffix"/>
              </xsl:call-template>
            </xsl:template>
            <xsl:template name="labelled">
              <xsl:param name="text" select='&quot;&quot;'/>
              <xsl:param name="ending" select='&quot;&quot;'/>
              <label><xsl:value-of select="concat($prefix, $text, $ending)"/></label>
            </xsl:template>
          </xsl:stylesheet>
        XSL
        result = transform(stylesheet, "<items><item>A</item></items>", {"prefix" => "X"})
        assert_equal("<root><label>XA-S</label></root>", result.to_s)
        modes = result.selections.collect { |selection| selection[:mode] }
        assert_include(modes, "{}label")
        call = result.selections.find { |selection| selection[:invocation].start_with?("call-template") }
        assert_equal("{}label", call[:mode])
        assert_include(call[:basis], "mode {}label is not changed")
      end

      def test_built_in_templates_recurse_and_copy_text
        stylesheet = <<~XSL
          <xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
            <xsl:template match="/">
              <root><xsl:apply-templates select="items/item/name"/></root>
            </xsl:template>
          </xsl:stylesheet>
        XSL
        result = transform(stylesheet, "<items><item><name>Alice</name></item></items>")
        assert_equal("<root>Alice</root>", result.to_s)
        kinds = result.selections.collect { |selection| selection[:chosen] }
        assert_include(kinds, "built-in template (builtin_children)")
        assert_include(kinds, "built-in template (builtin_text)")
      end

      def test_unsupported_instruction_is_rejected_before_execution
        stylesheet = <<~XSL
          <xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
            <xsl:template match="/" name="never-used">
              <xsl:if test="true()"><bad/></xsl:if>
            </xsl:template>
          </xsl:stylesheet>
        XSL
        error = assert_raise(XSLT::CompilationError) do
          transform(stylesheet, "<root/>")
        end
        assert_match("Unsupported XSLT instruction xsl:if", error.message)
      end

      def test_attribute_value_templates_are_rejected_before_execution
        stylesheet = <<~XSL
          <xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
            <xsl:template match="/"><a href="{{wrong}}"/></xsl:template>
          </xsl:stylesheet>
        XSL
        error = assert_raise(XSLT::CompilationError) do
          transform(stylesheet, "<root/>")
        end
        assert_match("Attribute value templates are not supported", error.message)
      end

      def test_missing_offline_resource_is_rejected
        stylesheet = <<~XSL
          <xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
            <xsl:import href="missing.xsl"/>
            <xsl:template match="/"/>
          </xsl:stylesheet>
        XSL
        error = assert_raise(XSLT::CompilationError) do
          transform(stylesheet, "<root/>")
        end
        assert_match("Missing offline stylesheet resource: missing.xsl", error.message)
      end
    end
  end
end
