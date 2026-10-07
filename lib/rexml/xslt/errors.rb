# frozen_string_literal: true

module REXML
  module XSLT
    # Base class for all errors raised by REXML::XSLT.
    class Error < StandardError; end

    # Raised when a stylesheet is not well formed for the supported
    # subset (bad root element, missing required attribute, malformed
    # pattern, misplaced xsl:import, ...).
    class StylesheetError < Error; end

    # Raised when a pattern cannot be parsed by the supported subset.
    class PatternError < StylesheetError; end

    # Raised when an xsl:import references a URI that is not present in
    # the explicit offline resource table.  Stylesheets are never fetched
    # from the filesystem or the network.
    class UnknownResourceError < StylesheetError; end

    # Raised when xsl:import forms a cycle.
    class CircularImportError < StylesheetError; end

    # Raised at compile time -- before any source node is processed --
    # when the stylesheet uses an XSLT instruction outside the supported
    # subset.
    class UnsupportedInstructionError < StylesheetError; end

    # Raised while a transformation is running (missing named template,
    # bad select expression, ...).
    class EvaluationError < Error; end
  end
end
