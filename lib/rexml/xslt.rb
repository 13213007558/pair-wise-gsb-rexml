# frozen_string_literal: true

# REXML::XSLT is a pure-Ruby evaluator for a small, well-defined subset of
# XSLT 1.0.  It exists so that simple transformations can run in a plain
# Ruby process without native extensions.
#
# Supported:
# * xsl:stylesheet / xsl:transform (version required)
# * xsl:import, resolved exclusively through an explicit offline resource
#   table (a Hash of URI => stylesheet source); nothing is ever read from
#   the filesystem or the network
# * xsl:template with match, name, mode and priority
# * xsl:apply-templates (select, mode, xsl:with-param)
# * xsl:call-template (name, xsl:with-param)
# * xsl:param (top level and inside templates, select only)
# * xsl:value-of (select)
# * xsl:text
# * literal result elements (attributes are copied verbatim; attribute
#   value templates are not evaluated)
# * the XSLT 1.0 built-in template rules
#
# Anything else in the XSLT namespace (xsl:for-each, xsl:if, xsl:variable,
# xsl:sort, ...) is rejected by the compiler *before* any node is
# processed, by raising REXML::XSLT::UnsupportedInstructionError.
#
# Template rule selection follows XSLT 1.0 section 5.5: highest import
# precedence wins, then highest priority (explicit priority first,
# otherwise the default priority derived from the pattern), and remaining
# ties are broken in favour of the template that appears last in document
# order.  Every selection is explained in plain language through the
# processor's trace log (see REXML::XSLT::Processor#trace_log).
#
# Example:
#   stylesheet = REXML::XSLT::Stylesheet.compile(xsl_source,
#                                                resources: {"common.xsl" => common_source})
#   processor  = REXML::XSLT::Processor.new(stylesheet)
#   puts processor.transform(xml_source)
#   puts processor.trace_log

require_relative "xslt/errors"
require_relative "xslt/pattern"
require_relative "xslt/stylesheet"
require_relative "xslt/processor"

module REXML
  module XSLT
    # The XSLT 1.0 namespace URI.
    NAMESPACE = "http://www.w3.org/1999/XSL/Transform"
  end
end
