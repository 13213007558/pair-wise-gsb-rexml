# frozen_string_literal: false

require "rexml/document"
require "rexml/xslt"

module REXMLTests
  class TestXSLT < Test::Unit::TestCase
    XSL_NAMESPACE = "http://www.w3.org/1999/XSL/Transform"

    private

    def transform(source_xml, stylesheet_xml, params={})
      source = REXML::Document.new(source_xml)
      stylesheet = REXML::Document.new(stylesheet_xml)
      REXML::XSLT.transform(source, stylesheet, params)
    end

    def stylesheet(body)
      <<~XML
        <xsl:stylesheet version="1.0" xmlns:xsl="#{XSL_NAMESPACE}">
          #{body}
        </xsl:stylesheet>
      XML
    end

    public

    # The acceptance stylesheet: wildcard and specific templates, two
    # modes, and a named template called from inside a traversal.  The
    # result shows exactly which template was selected for every node.
    def test_acceptance_stylesheet
      source_xml = "<catalog>" +                   "<item id='a'>first</item>" +                   "<item id='b'>second</item>" +                   "<note>memo</note>" +                   "</catalog>"
      stylesheet_xml = stylesheet(<<~XSL)
        <xsl:template match="/">
          <report>
            <summary><xsl:apply-templates select="/catalog/*" mode="summary"/></summary>
            <detail><xsl:apply-templates select="/catalog/*" mode="detail"/></detail>
          </report>
        </xsl:template>
        <xsl:template match="*" mode="summary">
          <other><xsl:value-of select="name()"/></other>
        </xsl:template>
        <xsl:template match="item" mode="summary">
          <counted><xsl:value-of select="@id"/></counted>
        </xsl:template>
        <xsl:template match="*" mode="detail">
          <skipped><xsl:value-of select="name()"/></skipped>
        </xsl:template>
        <xsl:template match="item" mode="detail">
          <row index="{position()}">
            <xsl:for-each select="text()">
              <xsl:call-template name="emit">
                <xsl:with-param name="value" select="."/>
              </xsl:call-template>
            </xsl:for-each>
          </row>
        </xsl:template>
        <xsl:template name="emit">
          <xsl:param name="value" select="'none'"/>
          <value-of-item><xsl:value-of select="$value"/></value-of-item>
        </xsl:template>
      XSL
      assert_equal("<report>" +                   "<summary>" +                   "<counted>a</counted><counted>b</counted><other>note</other>" +                   "</summary>" +                   "<detail>" +                   "<row index='1'><value-of-item>first</value-of-item></row>" +                   "<row index='2'><value-of-item>second</value-of-item></row>" +                   "<skipped>note</skipped>" +                   "</detail>" +                   "</report>",
                   transform(source_xml, stylesheet_xml).to_s)
    end

    def test_specific_template_beats_wildcard
      stylesheet_xml = stylesheet(<<~XSL)
        <xsl:template match="*">wild</xsl:template>
        <xsl:template match="item">specific</xsl:template>
        <xsl:template match="/"><out><xsl:apply-templates select="/root/*"/></out></xsl:template>
      XSL
      # Exactly one template fires per node: "specificwild", not
      # "specificwildwild" or "wildspecific".
      assert_equal("<out>specificwild</out>",
                   transform("<root><item/><other/></root>", stylesheet_xml).to_s)
    end

    def test_explicit_priority_overrides_default
      stylesheet_xml = stylesheet(<<~XSL)
        <xsl:template match="/"><out><xsl:apply-templates select="/root/item"/></out></xsl:template>
        <xsl:template match="item">zero</xsl:template>
        <xsl:template match="*" priority="2">wild-high</xsl:template>
      XSL
      assert_equal("<out>wild-high</out>",
                   transform("<root><item/></root>", stylesheet_xml).to_s)
    end

    def test_later_template_wins_priority_ties
      stylesheet_xml = stylesheet(<<~XSL)
        <xsl:template match="/"><out><xsl:apply-templates select="/root/item"/></out></xsl:template>
        <xsl:template match="item">first</xsl:template>
        <xsl:template match="item">second</xsl:template>
      XSL
      assert_equal("<out>second</out>",
                   transform("<root><item/></root>", stylesheet_xml).to_s)
    end

    def test_modes_select_different_templates
      stylesheet_xml = stylesheet(<<~XSL)
        <xsl:template match="/">
          <out>
            <one><xsl:apply-templates select="/root/item" mode="one"/></one>
            <two><xsl:apply-templates select="/root/item" mode="two"/></two>
            <none><xsl:apply-templates select="/root/item"/></none>
          </out>
        </xsl:template>
        <xsl:template match="item" mode="one">1</xsl:template>
        <xsl:template match="item" mode="two">2</xsl:template>
        <xsl:template match="item">0</xsl:template>
      XSL
      assert_equal("<out><one>1</one><two>2</two><none>0</none></out>",
                   transform("<root><item/></root>", stylesheet_xml).to_s)
    end

    def test_position_and_last_in_apply_templates
      stylesheet_xml = stylesheet(<<~XSL)
        <xsl:template match="/"><out><xsl:apply-templates select="/root/i"/></out></xsl:template>
        <xsl:template match="i"><xsl:value-of select="position()"/>/<xsl:value-of select="last()"/>;</xsl:template>
      XSL
      assert_equal("<out>1/2;2/2;</out>",
                   transform("<root><i/><i/></root>", stylesheet_xml).to_s)
    end

    def test_for_each_position_and_last
      stylesheet_xml = stylesheet(<<~XSL)
        <xsl:template match="/">
          <out>
            <xsl:for-each select="/root/i">
              <n><xsl:value-of select="position()"/>/<xsl:value-of select="last()"/>=<xsl:value-of select="."/></n>
            </xsl:for-each>
          </out>
        </xsl:template>
      XSL
      assert_equal("<out><n>1/3=a</n><n>2/3=b</n><n>3/3=c</n></out>",
                   transform("<root><i>a</i><i>b</i><i>c</i></root>", stylesheet_xml).to_s)
    end

    def test_call_template_params_have_their_own_scope
      stylesheet_xml = stylesheet(<<~XSL)
        <xsl:template match="/">
          <out>
            <xsl:call-template name="emit">
              <xsl:with-param name="v" select="'passed'"/>
            </xsl:call-template>
            <xsl:call-template name="emit"/>
            <after><xsl:value-of select="$v"/></after>
          </out>
        </xsl:template>
        <xsl:template name="emit">
          <xsl:param name="v" select="'default'"/>
          <got><xsl:value-of select="$v"/></got>
        </xsl:template>
      XSL
      assert_equal("<out><got>passed</got><got>default</got><after></after></out>",
                   transform("<root/>", stylesheet_xml).to_s)
    end

    def test_apply_templates_with_param
      stylesheet_xml = stylesheet(<<~XSL)
        <xsl:template match="/">
          <out>
            <xsl:apply-templates select="/root/item">
              <xsl:with-param name="suffix" select="'!'"/>
            </xsl:apply-templates>
          </out>
        </xsl:template>
        <xsl:template match="item">
          <xsl:param name="suffix" select="'?'"/>
          <v><xsl:value-of select="."/><xsl:value-of select="$suffix"/></v>
        </xsl:template>
      XSL
      assert_equal("<out><v>a!</v><v>b!</v></out>",
                   transform("<root><item>a</item><item>b</item></root>", stylesheet_xml).to_s)
    end

    def test_with_param_content_becomes_string
      stylesheet_xml = stylesheet(<<~XSL)
        <xsl:template match="/">
          <out>
            <xsl:call-template name="emit">
              <xsl:with-param name="v">literal</xsl:with-param>
            </xsl:call-template>
          </out>
        </xsl:template>
        <xsl:template name="emit">
          <xsl:param name="v"/>
          <got><xsl:value-of select="$v"/></got>
        </xsl:template>
      XSL
      assert_equal("<out><got>literal</got></out>",
                   transform("<root/>", stylesheet_xml).to_s)
    end

    def test_top_level_param_and_override
      stylesheet_xml = stylesheet(<<~XSL)
        <xsl:param name="g" select="'default'"/>
        <xsl:template match="/"><out><xsl:value-of select="$g"/></out></xsl:template>
      XSL
      assert_equal("<out>default</out>",
                   transform("<root/>", stylesheet_xml).to_s)
      assert_equal("<out>given</out>",
                   transform("<root/>", stylesheet_xml, {"g" => "given"}).to_s)
    end

    def test_choose_and_if
      stylesheet_xml = stylesheet(<<~XSL)
        <xsl:template match="/">
          <out>
            <xsl:for-each select="/root/n">
              <xsl:choose>
                <xsl:when test=". &lt; 2">low</xsl:when>
                <xsl:when test=". = 2">mid</xsl:when>
                <xsl:otherwise>high</xsl:otherwise>
              </xsl:choose>
              <xsl:if test="@mark = 'yes'">!</xsl:if>
            </xsl:for-each>
          </out>
        </xsl:template>
      XSL
      source_xml = "<root><n>1</n><n mark='yes'>2</n><n>3</n></root>"
      assert_equal("<out>lowmid!high</out>",
                   transform(source_xml, stylesheet_xml).to_s)
    end

    def test_value_of_type_conversions
      stylesheet_xml = stylesheet(<<~XSL)
        <xsl:template match="/">
          <out>
            <n><xsl:value-of select="1 + 2"/></n>
            <f><xsl:value-of select="5 div 2"/></f>
            <b><xsl:value-of select="true()"/></b>
            <s><xsl:value-of select="'lit'"/></s>
            <e><xsl:value-of select="/root/missing"/></e>
            <a><xsl:value-of select="/root/item/@id"/></a>
          </out>
        </xsl:template>
      XSL
      assert_equal("<out><n>3</n><f>2.5</f><b>true</b><s>lit</s><e></e><a>x7</a></out>",
                   transform("<root><item id='x7'/></root>", stylesheet_xml).to_s)
    end

    def test_literal_result_elements_and_namespaces
      stylesheet_xml = <<~XML
        <xsl:stylesheet version="1.0"
                        xmlns:xsl="#{XSL_NAMESPACE}"
                        xmlns:o="urn:out">
          <xsl:template match="/">
            <o:result id="{/root/item/@id}">
              <plain>text</plain>
            </o:result>
          </xsl:template>
        </xsl:stylesheet>
      XML
      assert_equal("<o:result id='i1' xmlns:o='urn:out'><plain>text</plain></o:result>",
                   transform("<root><item id='i1'/></root>", stylesheet_xml).to_s)
    end

    def test_builtin_templates_recurse_and_copy_text
      stylesheet_xml = stylesheet(<<~XSL)
        <xsl:template match="/">
          <out><xsl:apply-templates select="/root"/></out>
        </xsl:template>
      XSL
      assert_equal("<out>Hello, bold world!</out>",
                   transform("<root>Hello, <b>bold</b> world!</root>",
                             stylesheet_xml).to_s)
    end

    def test_pattern_child_and_descendant_paths
      stylesheet_xml = stylesheet(<<~XSL)
        <xsl:template match="/"><out><xsl:apply-templates select="/root//b"/></out></xsl:template>
        <xsl:template match="a//b">deep</xsl:template>
        <xsl:template match="a/b">child</xsl:template>
        <xsl:template match="b">plain</xsl:template>
      XSL
      source_xml = "<root><a><b/><c><b/></c></a><b/></root>"
      assert_equal("<out>childdeepplain</out>",
                   transform(source_xml, stylesheet_xml).to_s)
    end

    def test_namespaced_patterns
      stylesheet_xml = <<~XML
        <xsl:stylesheet version="1.0"
                        xmlns:xsl="#{XSL_NAMESPACE}"
                        xmlns:s="urn:s">
          <xsl:template match="/"><out><xsl:apply-templates select="/root/*"/></out></xsl:template>
          <xsl:template match="s:entry">[s:<xsl:value-of select="."/>]</xsl:template>
          <xsl:template match="entry">[plain:<xsl:value-of select="."/>]</xsl:template>
        </xsl:stylesheet>
      XML
      source_xml = "<root xmlns:s='urn:s'><s:entry>1</s:entry><entry>2</entry></root>"
      assert_equal("<out xmlns:s='urn:s'>[s:1][plain:2]</out>",
                   transform(source_xml, stylesheet_xml).to_s)
    end

    def test_attribute_pattern_and_builtin_attribute_template
      stylesheet_xml = stylesheet(<<~XSL)
        <xsl:template match="/">
          <out><xsl:apply-templates select="/root/item/@*"/></out>
        </xsl:template>
        <xsl:template match="@id">[<xsl:value-of select="."/>]</xsl:template>
      XSL
      assert_equal("<out>[i]o</out>",
                   transform("<root><item id='i' other='o'/></root>",
                             stylesheet_xml).to_s)
    end

    def test_union_pattern
      stylesheet_xml = stylesheet(<<~XSL)
        <xsl:template match="/"><out><xsl:apply-templates select="/root/*"/></out></xsl:template>
        <xsl:template match="a|c">hit</xsl:template>
        <xsl:template match="*">miss</xsl:template>
      XSL
      assert_equal("<out>hitmisshit</out>",
                   transform("<root><a/><b/><c/></root>", stylesheet_xml).to_s)
    end

    def test_apply_templates_default_select_is_child_nodes
      stylesheet_xml = stylesheet(<<~XSL)
        <xsl:template match="/"><out><xsl:apply-templates/></out></xsl:template>
      XSL
      assert_equal("<out>Hello, bold!</out>",
                   transform("<root>Hello, <b>bold</b>!</root>", stylesheet_xml).to_s)
    end

    def test_inputs_are_not_modified
      source = REXML::Document.new("<root><item id='a'>text</item></root>")
      stylesheet_document = REXML::Document.new(stylesheet(<<~XSL))
        <xsl:template match="/">
          <out><xsl:apply-templates select="/root/item"/></out>
        </xsl:template>
        <xsl:template match="item"><copy><xsl:value-of select="."/></copy></xsl:template>
      XSL
      source_before = source.to_s
      stylesheet_before = stylesheet_document.to_s
      REXML::XSLT.transform(source, stylesheet_document)
      assert_equal(source_before, source.to_s)
      assert_equal(stylesheet_before, stylesheet_document.to_s)
    end

    def test_transformer_can_be_reused
      transformer = REXML::XSLT::Transformer.new(
        REXML::Document.new(stylesheet(<<~XSL))
          <xsl:template match="/"><out><xsl:value-of select="/root/i"/></out></xsl:template>
        XSL
      )
      assert_equal("<out>1</out>",
                   transformer.transform(REXML::Document.new("<root><i>1</i></root>")).to_s)
      assert_equal("<out>2</out>",
                   transformer.transform(REXML::Document.new("<root><i>2</i></root>")).to_s)
    end

    def test_diagnoses_import_and_include
      ["<xsl:import href='other.xsl'/>",
       "<xsl:include href='other.xsl'/>"].each do |element|
        error = assert_raise(REXML::XSLT::Error) do
          transform("<root/>", stylesheet(element))
        end
        assert_match(/unsupported top-level XSLT element/, error.message)
      end
    end

    def test_diagnoses_unsupported_instructions
      ["<xsl:variable name='v' select='1'/>",
       "<xsl:sort select='.'/>",
       "<xsl:copy-of select='.'/>",
       "<xsl:number/>"].each do |instruction|
        error = assert_raise(REXML::XSLT::Error) do
          transform("<root/>",
                    stylesheet("<xsl:template match='/'>#{instruction}</xsl:template>"))
        end
        assert_match(/unsupported XSLT instruction/, error.message)
      end
    end

    def test_diagnoses_document_function
      error = assert_raise(REXML::XSLT::Error) do
        transform("<root/>",
                  stylesheet("<xsl:template match='/'>" +                             "<xsl:value-of select=\"document('other.xml')\"/>" +                             "</xsl:template>"))
      end
      assert_match(/document\(\) is not supported/, error.message)
    end

    def test_diagnoses_pattern_predicates
      error = assert_raise(REXML::XSLT::Error) do
        transform("<root><item/></root>",
                  stylesheet("<xsl:template match='item[1]'>x</xsl:template>"))
      end
      assert_match(/predicates in match patterns are not supported/, error.message)
    end

    def test_diagnoses_unbound_pattern_prefix
      error = assert_raise(REXML::XSLT::Error) do
        transform("<root/>",
                  stylesheet("<xsl:template match='q:item'>x</xsl:template>"))
      end
      assert_match(/unbound namespace prefix/, error.message)
    end

    def test_diagnoses_unknown_named_template
      error = assert_raise(REXML::XSLT::Error) do
        transform("<root/>",
                  stylesheet("<xsl:template match='/'>" +                             "<xsl:call-template name='missing'/>" +                             "</xsl:template>"))
      end
      assert_match(/no template named/, error.message)
    end

    def test_diagnoses_non_nodeset_select
      error = assert_raise(REXML::XSLT::Error) do
        transform("<root/>",
                  stylesheet("<xsl:template match='/'>" +                             "<xsl:for-each select=\"'text'\">x</xsl:for-each>" +                             "</xsl:template>"))
      end
      assert_match(/must be a node-set/, error.message)
    end

    def test_diagnoses_bad_stylesheet_root
      error = assert_raise(REXML::XSLT::Error) do
        transform("<root/>", "<not-a-stylesheet/>")
      end
      assert_match(/xsl:stylesheet or xsl:transform/, error.message)
    end
  end
end
