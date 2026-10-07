# frozen_string_literal: true

require "test/unit"

require "rexml/xslt"

module REXMLTests
  class TestXSLT < Test::Unit::TestCase
    XSL = REXML::XSLT::NAMESPACE

    def stylesheet(*body)
      %(<xsl:stylesheet xmlns:xsl="#{XSL}" version="1.0">#{body.join("\n")}</xsl:stylesheet>)
    end

    def compile(*body, resources: {})
      REXML::XSLT::Stylesheet.compile(stylesheet(*body), resources: resources)
    end

    def transform(*body, xml:, resources: {}, params: {})
      sheet = compile(*body, resources: resources)
      processor = REXML::XSLT::Processor.new(sheet, params: params)
      [processor.transform(xml), processor]
    end

    # -- basics ---------------------------------------------------------

    def test_literal_result_elements_and_value_of
      output, = transform(
        %(<xsl:template match="/"><html><body><xsl:value-of select="doc/title"/></body></html></xsl:template>),
        xml: %(<doc><title>Hello</title></doc>),
      )
      assert_equal(%(<html><body>Hello</body></html>), output)
    end

    def test_apply_templates_recurses_with_builtin_rules
      output, = transform(
        %(<xsl:template match="doc"><out><xsl:apply-templates/></out></xsl:template>),
        xml: %(<doc>a<b>b</b>c</doc>),
      )
      # <b> has no rule: the built-in element rule processes its children,
      # text nodes are copied by the built-in text rule.
      assert_equal(%(<out>abc</out>), output)
    end

    def test_value_of_attribute_and_number
      output, = transform(
        %(<xsl:template match="item"><xsl:value-of select="@id"/>|<xsl:value-of select="1+1"/></xsl:template>),
        xml: %(<item id="7"/>),
      )
      assert_equal(%(7|2), output)
    end

    def test_xsl_text_preserves_whitespace
      output, = transform(
        %(<xsl:template match="/"><a><xsl:text>  x  </xsl:text></a></xsl:template>),
        xml: %(<doc/>),
      )
      assert_equal(%(<a>  x  </a>), output)
    end

    def test_comments_are_discarded_by_builtin_rule
      output, = transform(
        %(<xsl:template match="/"><out><xsl:apply-templates/></out></xsl:template>),
        xml: %(<doc><!-- gone -->text</doc>),
      )
      assert_equal(%(<out>text</out>), output)
    end

    # -- default priorities and overlapping templates --------------------

    def test_default_priority_orders_overlapping_templates
      output, processor = transform(
        %(<xsl:template match="/"><xsl:apply-templates/></xsl:template>),
        %(<xsl:template match="list"><xsl:apply-templates/></xsl:template>),
        %(<xsl:template match="*">[wild]</xsl:template>),
        %(<xsl:template match="item">[name]</xsl:template>),
        %(<xsl:template match="list/item">[path]</xsl:template>),
        xml: %(<list><item/></list>),
      )
      # list/item (0.5) beats item (0) beats * (-0.5)
      assert_equal(%([path]), output)
      selection = processor.trace_log.find { |entry| entry.include?("<item>") }
      assert_match(%r{candidate xsl:template\[match="\*"\].*priority=-0.5}, selection)
      assert_match(%r{candidate xsl:template\[match="item"\].*priority=0}, selection)
      assert_match(%r{candidate xsl:template\[match="list/item"\].*priority=0.5}, selection)
      assert_match(%r{selected xsl:template\[match="list/item"\].*highest priority \(0.5\)}, selection)
    end

    def test_qname_beats_wildcard_when_path_does_not_match
      output, = transform(
        %(<xsl:template match="/"><xsl:apply-templates/></xsl:template>),
        %(<xsl:template match="other"><xsl:apply-templates/></xsl:template>),
        %(<xsl:template match="*">[wild]</xsl:template>),
        %(<xsl:template match="item">[name]</xsl:template>),
        %(<xsl:template match="list/item">[path]</xsl:template>),
        xml: %(<other><item/></other>),
      )
      assert_equal(%([name]), output)
    end

    def test_explicit_priority_overrides_default_priority
      output, = transform(
        %(<xsl:template match="*" priority="10">[wild]</xsl:template>),
        %(<xsl:template match="item">[name]</xsl:template>),
        xml: %(<item/>),
      )
      assert_equal(%([wild]), output)
    end

    def test_union_pattern_uses_per_alternative_default_priorities
      output, = transform(
        %(<xsl:template match="/"><xsl:apply-templates/></xsl:template>),
        %(<xsl:template match="list"><xsl:apply-templates/></xsl:template>),
        %(<xsl:template match="*">[wild]</xsl:template>),
        %(<xsl:template match="a | list/b">[union]</xsl:template>),
        xml: %(<list><b/></list>),
      )
      # The "list/b" alternative has default priority 0.5 and beats "*".
      assert_equal(%([union]), output)
    end

    def test_document_order_breaks_ties
      output, processor = transform(
        %(<xsl:template match="note">[first]</xsl:template>),
        %(<xsl:template match="note">[second]</xsl:template>),
        xml: %(<note/>),
      )
      assert_equal(%([second]), output)
      selection = processor.trace_log.find { |entry| entry.include?("<note>") }
      assert_match(/latest in document order wins/, selection)
    end

    # -- import precedence ------------------------------------------------

    def test_import_precedence_beats_priority
      imported = stylesheet(
        %(<xsl:template match="item" priority="99">[imported]</xsl:template>),
      )
      output, processor = transform(
        %(<xsl:import href="base.xsl"/>),
        %(<xsl:template match="item">[main]</xsl:template>),
        xml: %(<item/>),
        resources: {"base.xsl" => imported},
      )
      # Import precedence is considered before priority: the main
      # stylesheet wins even though the imported rule has priority 99.
      assert_equal(%([main]), output)
      selection = processor.trace_log.find { |entry| entry.include?("<item>") }
      assert_match(/highest import precedence \(2\)/, selection)
      assert_match(%r{precedence=1 priority=99}, selection)
    end

    def test_later_import_beats_earlier_import
      earlier = stylesheet(%(<xsl:template match="item">[earlier]</xsl:template>))
      later = stylesheet(%(<xsl:template match="item">[later]</xsl:template>))
      output, = transform(
        %(<xsl:import href="earlier.xsl"/>),
        %(<xsl:import href="later.xsl"/>),
        xml: %(<item/>),
        resources: {"earlier.xsl" => earlier, "later.xsl" => later},
      )
      assert_equal(%([later]), output)
    end

    def test_imported_named_template_is_shadowed
      imported = stylesheet(%(<xsl:template name="t">[imported]</xsl:template>))
      output, = transform(
        %(<xsl:import href="base.xsl"/>),
        %(<xsl:template name="t">[main]</xsl:template>),
        %(<xsl:template match="/"><xsl:call-template name="t"/></xsl:template>),
        xml: %(<doc/>),
        resources: {"base.xsl" => imported},
      )
      assert_equal(%([main]), output)
    end

    def test_unknown_import_resource_raises
      error = assert_raise(REXML::XSLT::UnknownResourceError) do
        compile(%(<xsl:import href="file:///etc/passwd"/>))
      end
      assert_match(/offline resource table/, error.message)
    end

    def test_circular_import_raises
      a = stylesheet(%(<xsl:import href="b.xsl"/>))
      b = stylesheet(%(<xsl:import href="a.xsl"/>))
      assert_raise(REXML::XSLT::CircularImportError) do
        REXML::XSLT::Stylesheet.compile(a, resources: {"a.xsl" => a, "b.xsl" => b},
                                         base_uri: "a.xsl")
      end
    end

    def test_import_after_other_definitions_raises
      assert_raise(REXML::XSLT::StylesheetError) do
        compile(
          %(<xsl:template match="/"/>),
          %(<xsl:import href="base.xsl"/>),
        )
      end
    end

    # -- modes -------------------------------------------------------------

    def test_modes_select_distinct_templates
      output, = transform(
        %(<xsl:template match="item">[body]</xsl:template>),
        %(<xsl:template match="item" mode="toc">[toc]</xsl:template>),
        %(<xsl:template match="/">) +
          %(<xsl:apply-templates select="doc/item"/>) +
          %(<xsl:apply-templates select="doc/item" mode="toc"/>) +
        %(</xsl:template>),
        xml: %(<doc><item/></doc>),
      )
      assert_equal(%([body][toc]), output)
    end

    def test_mode_is_kept_across_nested_apply_templates
      output, processor = transform(
        %(<xsl:template match="chapter" mode="toc">) +
          %(<toc><xsl:apply-templates select="section"/></toc>) +
        %(</xsl:template>),
        %(<xsl:template match="section" mode="toc"><s><xsl:value-of select="@n"/></s></xsl:template>),
        %(<xsl:template match="/"><xsl:apply-templates select="doc/chapter" mode="toc"/></xsl:template>),
        xml: %(<doc><chapter><section n="1"/><section n="2"/></chapter></doc>),
      )
      # apply-templates inside the mode="toc" template stays in mode toc.
      assert_equal(%(<toc><s>1</s><s>2</s></toc>), output)
      assert(processor.trace_log.any? { |entry| entry.include?("mode: toc") })
    end

    def test_builtin_rules_apply_per_mode
      output, processor = transform(
        %(<xsl:template match="section" mode="toc"><s/></xsl:template>),
        %(<xsl:template match="/"><xsl:apply-templates select="doc" mode="toc"/></xsl:template>),
        xml: %(<doc><section/></doc>),
      )
      # <doc> has no rule in mode toc: the built-in element rule recurses
      # in the same mode and reaches the section rule.
      assert_equal(%(<s/>), output)
      builtin = processor.trace_log.find { |entry| entry.include?("<doc>") }
      assert_match(/built-in template rule for the root node and elements/, builtin)
      assert_match(/mode: toc/, builtin)
    end

    # -- named templates and parameters -------------------------------------

    def test_call_template_with_params
      output, = transform(
        %(<xsl:template name="greet">) +
          %(<xsl:param name="who" select="'world'"/>) +
          %(<hello><xsl:value-of select="$who"/></hello>) +
        %(</xsl:template>),
        %(<xsl:template match="/">) +
          %(<xsl:call-template name="greet"/>) +
          %(<xsl:call-template name="greet"><xsl:with-param name="who" select="'ruby'"/></xsl:call-template>) +
        %(</xsl:template>),
        xml: %(<doc/>),
      )
      assert_equal(%(<hello>world</hello><hello>ruby</hello>), output)
    end

    def test_apply_templates_passes_params
      output, = transform(
        %(<xsl:template match="item">) +
          %(<xsl:param name="suffix" select="'!'"/>) +
          %(<i><xsl:value-of select="."/><xsl:value-of select="$suffix"/></i>) +
        %(</xsl:template>),
        %(<xsl:template match="/">) +
          %(<xsl:apply-templates select="doc/item">) +
            %(<xsl:with-param name="suffix" select="'?'"/>) +
          %(</xsl:apply-templates>) +
        %(</xsl:template>),
        xml: %(<doc><item>hey</item></doc>),
      )
      assert_equal(%(<i>hey?</i>), output)
    end

    def test_global_params_and_external_override
      output, = transform(
        %(<xsl:param name="title" select="'default'"/>),
        %(<xsl:template match="/"><h1><xsl:value-of select="$title"/></h1></xsl:template>),
        xml: %(<doc/>),
        params: {"title" => "custom"},
      )
      assert_equal(%(<h1>custom</h1>), output)
    end

    def test_global_param_default_used_without_override
      output, = transform(
        %(<xsl:param name="title" select="'default'"/>),
        %(<xsl:template match="/"><h1><xsl:value-of select="$title"/></h1></xsl:template>),
        xml: %(<doc/>),
      )
      assert_equal(%(<h1>default</h1>), output)
    end

    def test_unknown_named_template_raises_at_evaluation
      sheet = compile(%(<xsl:template match="/"><xsl:call-template name="nope"/></xsl:template>))
      assert_raise(REXML::XSLT::EvaluationError) do
        REXML::XSLT::Processor.new(sheet).transform(%(<doc/>))
      end
    end

    # -- static validation: unsupported instructions fail before execution --

    def test_unsupported_instructions_raise_at_compile_time
      [
        %(<xsl:template match="/"><xsl:for-each select="a"/></xsl:template>),
        %(<xsl:template match="/"><xsl:if test="a">x</xsl:if></xsl:template>),
        %(<xsl:variable name="v" select="1"/>),
        %(<xsl:template match="/"><xsl:apply-templates><xsl:sort select="a"/></xsl:apply-templates></xsl:template>),
        %(<xsl:template match="/"><xsl:copy-of select="."/></xsl:template>),
        %(<xsl:template match="/"><xsl:frobnicate/></xsl:template>),
      ].each do |body|
        error = assert_raise(REXML::XSLT::UnsupportedInstructionError) do
          compile(body)
        end
        assert_match(/not supported/, error.message)
      end
    end

    def test_unsupported_instruction_fails_before_any_processing
      # The unsupported instruction sits behind a template that would
      # crash if it were ever executed; compilation must fail first.
      sheet_source = stylesheet(
        %(<xsl:template match="/"><xsl:value-of select="$undefined"/></xsl:template>),
        %(<xsl:template match="late"><xsl:for-each select="a"/></xsl:template>),
      )
      assert_raise(REXML::XSLT::UnsupportedInstructionError) do
        REXML::XSLT::Stylesheet.compile(sheet_source)
      end
    end

    def test_pattern_predicates_are_rejected
      assert_raise(REXML::XSLT::PatternError) do
        compile(%(<xsl:template match="a[@x='1']"/>))
      end
    end

    def test_param_with_content_default_is_rejected
      assert_raise(REXML::XSLT::UnsupportedInstructionError) do
        compile(%(<xsl:param name="p"><b/></xsl:param>))
      end
    end

    def test_stylesheet_root_is_required
      assert_raise(REXML::XSLT::StylesheetError) do
        REXML::XSLT::Stylesheet.compile(%(<not-a-stylesheet/>))
      end
    end

    # -- trace --------------------------------------------------------------

    def test_trace_explains_every_selection
      _, processor = transform(
        %(<xsl:template match="item">[name]</xsl:template>),
        xml: %(<doc><item/></doc>),
      )
      log = processor.trace_log.join("\n")
      # User rule selection lists candidates and a reason.
      assert_match(/template selection for element <item>/, log)
      assert_match(/candidate rule/, log)
      assert_match(/=> selected xsl:template\[match="item"\]/, log)
      # Unmatched nodes fall back to built-in rules, also explained.
      assert_match(/template selection for element <doc> \(mode: #default\): no template rule matches/, log)
      assert_match(/built-in template rule for the root node and elements/, log)
    end

    def test_trace_is_reset_between_transforms
      sheet = compile(%(<xsl:template match="/">ok</xsl:template>))
      processor = REXML::XSLT::Processor.new(sheet)
      processor.transform(%(<doc/>))
      first = processor.trace_log.size
      processor.transform(%(<doc/>))
      assert_equal(first, processor.trace_log.size)
    end
  end
end
