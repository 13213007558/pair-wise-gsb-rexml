# frozen_string_literal: false
require_relative "../child"
require_relative "content_model"

module REXML
  module DTD
    class ElementDecl < Child
      START = "<!ELEMENT"
      START_RE = /^\s*#{START}/um
      # PATTERN_RE = /^\s*(#{START}.*?)>/um
      PATTERN_RE = /^\s*#{START}\s+((?:[:\w][-\.\w]*:)?[-!\*\.\w]*)(.*?)>/
      #\s*((((["']).*?\5)|[^\/'">]*)*?)(\/)?>/um, true)

      def initialize match
        if match.kind_of?(String)
          match = PATTERN_RE.match(match)
        end
        @name = match[1]
        @rest = match[2]
      end

      attr_reader :name

      # Parses the content specification of this declaration into a
      # REXML::DTD::ContentModel, which can validate sequences of child
      # element names.  Raises ContentModel::AmbiguityError when the
      # content model is not deterministic.
      def content_model
        ContentModel.parse(@rest.strip)
      end
    end
  end
end
