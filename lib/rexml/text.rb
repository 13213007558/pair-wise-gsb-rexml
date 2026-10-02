# frozen_string_literal: true
require_relative 'security'
require_relative 'entity'
require_relative 'doctype'
require_relative 'child'
require_relative 'doctype'
require_relative 'parseexception'

module REXML
  # Represents text nodes in an XML document
  class Text < Child
    include Comparable
    # The order in which the substitutions occur
    SPECIALS = [ /&(?!#?[\w-]+;)/u, /</u, />/u, /"/u, /'/u, /\r/u ].freeze
    SUBSTITUTES = ['&amp;', '&lt;', '&gt;', '&quot;', '&apos;', '&#13;'].freeze
    # Characters which are substituted in written strings
    SLAICEPS = [ '<', '>', '"', "'", '&' ].freeze
    SETUTITSBUS = [ /&lt;/u, /&gt;/u, /&quot;/u, /&apos;/u, /&amp;/u ].freeze

    # If +raw+ is true, then REXML leaves the value alone
    attr_accessor :raw

    NEEDS_A_SECOND_CHECK = /(<|&((#{Entity::NAME});|(#0*((?:\d+)|(?:x[a-fA-F0-9]+)));)?)/um
    NUMERICENTITY = /&#0*((?:\d+)|(?:x[a-fA-F0-9]+));/
    VALID_CHAR = [
      0x9, 0xA, 0xD,
      (0x20..0xD7FF),
      (0xE000..0xFFFD),
      (0x10000..0x10FFFF)
    ].freeze

    # Characters that are legal in an XML 1.1 document.  Compared to
    # VALID_CHAR, almost all control characters are allowed; only NUL,
    # the surrogate blocks and U+FFFE/U+FFFF are excluded.  The control
    # characters that XML 1.1 calls "restricted characters" (#x1-#x8,
    # #xB-#xC, #xE-#x1F and #x7F-#x9F) are included here so that they
    # are accepted both literally and as character references.
    VALID_CHAR_XML_1_1 = [
      (0x1..0xD7FF),
      (0xE000..0xFFFD),
      (0x10000..0x10FFFF)
    ].freeze

    VALID_XML_CHARS = Regexp.new('^['+
      VALID_CHAR.map { |item|
        case item
        when Integer
          [item].pack('U').force_encoding('utf-8')
        when Range
          [item.first, '-'.ord, item.last].pack('UUU').force_encoding('utf-8')
        end
      }.join +
    ']*$').freeze

    VALID_XML_CHARS_XML_1_1 = Regexp.new('^['+
      VALID_CHAR_XML_1_1.map { |item|
        case item
        when Integer
          [item].pack('U').force_encoding('utf-8')
        when Range
          [item.first, '-'.ord, item.last].pack('UUU').force_encoding('utf-8')
        end
      }.join +
    ']*$').freeze

    # Line ending sequences.  XML 1.0 only treats #xD #xA and #xD as
    # line endings; XML 1.1 additionally recognizes NEL (#x85) and LS
    # (#x2028), including the two-character sequence #xD #x85.
    LINE_ENDINGS = /\r\n?/
    LINE_ENDINGS_XML_1_1 = /\r\n|\r\u{85}|[\r\u{85}\u{2028}]/

    # Constructor
    # +arg+ if a String, the content is set to the String.  If a Text,
    # the object is shallowly cloned.
    #
    # +respect_whitespace+ (boolean, false) if true, whitespace is
    # respected
    #
    # +parent+ (nil) if this is a Parent object, the parent
    # will be set to this.
    #
    # +raw+ (nil) This argument can be given three values.
    # If true, then the value of used to construct this object is expected to
    # contain no unescaped XML markup, and REXML will not change the text. If
    # this value is false, the string may contain any characters, and REXML will
    # escape any and all defined entities whose values are contained in the
    # text.  If this value is nil (the default), then the raw value of the
    # parent will be used as the raw value for this node.  If there is no raw
    # value for the parent, and no value is supplied, the default is false.
    # Use this field if you have entities defined for some text, and you don't
    # want REXML to escape that text in output.
    #   Text.new( "<&", false, nil, false ) #-> "&lt;&amp;"
    #   Text.new( "&lt;&amp;", false, nil, false ) #-> "&amp;lt;&amp;amp;"
    #   Text.new( "<&", false, nil, true )  #-> Parse exception
    #   Text.new( "&lt;&amp;", false, nil, true )  #-> "&lt;&amp;"
    #   # Assume that the entity "s" is defined to be "sean"
    #   # and that the entity    "r" is defined to be "russell"
    #   Text.new( "sean russell" )          #-> "&s; &r;"
    #   Text.new( "sean russell", false, nil, true ) #-> "sean russell"
    #
    # +entity_filter+ (nil) This can be an array of entities to match in the
    # supplied text.  This argument is only useful if +raw+ is set to false.
    #   Text.new( "sean russell", false, nil, false, ["s"] ) #-> "&s; russell"
    #   Text.new( "sean russell", false, nil, true, ["s"] ) #-> "sean russell"
    # In the last example, the +entity_filter+ argument is ignored.
    #
    # +illegal+ INTERNAL USE ONLY
    def initialize(arg, respect_whitespace=false, parent=nil, raw=nil,
      entity_filter=nil, illegal=NEEDS_A_SECOND_CHECK )

      @raw = false
      @parent = nil
      @entity_filter = nil

      if parent
        super( parent )
        @raw = parent.raw
      end

      if arg.kind_of? String
        @string = arg.dup
      elsif arg.kind_of? Text
        @string = arg.instance_variable_get(:@string).dup
        @raw = arg.raw
        @entity_filter = arg.instance_variable_get(:@entity_filter)
      else
        raise "Illegal argument of type #{arg.type} for Text constructor (#{arg})"
      end

      @string.squeeze!(" \n\t") unless respect_whitespace
      @string.gsub!(LINE_ENDINGS, "\n")
      @raw = raw unless raw.nil?
      @entity_filter = entity_filter if entity_filter
      clear_cache

      Text.check(@string, illegal, nil,
                 xml_version: Text.declared_xml_version(document)) if @raw
    end

    def parent= parent
      super(parent)
      if @raw and @parent
        Text.check(@string, NEEDS_A_SECOND_CHECK, nil,
                   xml_version: Text.declared_xml_version(document))
      end
    end

    # check for illegal characters
    def Text.check string, pattern, doctype = nil, xml_version: nil
      if xml_version == "1.1"
        valid_char = VALID_CHAR_XML_1_1
        valid_xml_chars = VALID_XML_CHARS_XML_1_1
      else
        valid_char = VALID_CHAR
        valid_xml_chars = VALID_XML_CHARS
      end

      # illegal anywhere
      if !string.match?(valid_xml_chars)
        string.chars.each do |c|
          case c.ord
          when *valid_char
          else
            raise "Illegal character #{c.inspect} in raw string #{string.inspect}"
          end
        end
      end

      pos = 0
      while (index = string.index(/<|&/, pos))
        if string[index] == "<"
          raise "Illegal character \"#{string[index]}\" in raw string #{string.inspect}"
        end

        unless (end_index = string.index(/[^\s];/, index + 1))
          raise "Illegal character \"#{string[index]}\" in raw string #{string.inspect}"
        end

        value = string[(index + 1)..end_index]
        if /\s/.match?(value)
          raise "Illegal character \"#{string[index]}\" in raw string #{string.inspect}"
        end

        if value[0] == "#"
          character_reference = value[1..-1]

          unless (/\A(\d+|x[0-9a-fA-F]+)\z/.match?(character_reference))
            if character_reference[0] == "x" || character_reference[-1] == "x"
              raise "Illegal character \"#{string[index]}\" in raw string #{string.inspect}"
            else
              raise "Illegal character #{string.inspect} in raw string #{string.inspect}"
            end
          end

          case (character_reference[0] == "x" ? character_reference[1..-1].to_i(16) : character_reference[0..-1].to_i)
          when *valid_char
          else
            raise "Illegal character #{string.inspect} in raw string #{string.inspect}"
          end
        elsif !(/\A#{Entity::NAME}\z/um.match?(value))
          raise "Illegal character \"#{string[index]}\" in raw string #{string.inspect}"
        end

        pos = end_index + 1
      end

      string
    end

    def node_type
      :text
    end

    def empty?
      @string.size==0
    end


    def clone
      Text.new(self, true)
    end


    # Appends text to this text node.  The text is appended in the +raw+ mode
    # of this text node.
    #
    # +returns+ the text itself to enable method chain like
    # 'text << "XXX" << "YYY"'.
    def <<( to_append )
      @string << to_append.gsub( LINE_ENDINGS, "\n" )
      clear_cache
      self
    end


    # +other+ a String or a Text
    # +returns+ the result of (to_s <=> arg.to_s)
    def <=>( other )
      to_s() <=> other.to_s
    end

    def doctype
      @parent&.document&.doctype
    end

    REFERENCE = /#{Entity::REFERENCE}/
    # Returns the string value of this text node.  This string is always
    # escaped, meaning that it is a valid XML text node string, and all
    # entities that can be escaped, have been inserted.  This method respects
    # the entity filter set in the constructor.
    #
    #   # Assume that the entity "s" is defined to be "sean", and that the
    #   # entity "r" is defined to be "russell"
    #   t = Text.new( "< & sean russell", false, nil, false, ['s'] )
    #   t.to_s   #-> "&lt; &amp; &s; russell"
    #   t = Text.new( "< & &s; russell", false, nil, false )
    #   t.to_s   #-> "&lt; &amp; &s; russell"
    #   u = Text.new( "sean russell", false, nil, true )
    #   u.to_s   #-> "sean russell"
    def to_s
      return @string if @raw
      @normalized ||= Text::normalize( @string, doctype, @entity_filter )
    end

    def inspect
      @string.inspect
    end

    # Returns the string value of this text.  This is the text without
    # entities, as it might be used programmatically, or printed to the
    # console.  This ignores the 'raw' attribute setting, and any
    # entity_filter.
    #
    #   # Assume that the entity "s" is defined to be "sean", and that the
    #   # entity "r" is defined to be "russell"
    #   t = Text.new( "< & sean russell", false, nil, false, ['s'] )
    #   t.value   #-> "< & sean russell"
    #   t = Text.new( "< & &s; russell", false, nil, false )
    #   t.value   #-> "< & sean russell"
    #   u = Text.new( "sean russell", false, nil, true )
    #   u.value   #-> "sean russell"
    def value
      @unnormalized ||= Text::unnormalize(@string, doctype,
                                          entity_expansion_text_limit: document&.entity_expansion_text_limit,
                                          xml_version: Text.declared_xml_version(document))
    end

    # Sets the contents of this text node.  This expects the text to be
    # unnormalized.  It returns self.
    #
    #   e = Element.new( "a" )
    #   e.add_text( "foo" )   # <a>foo</a>
    #   e[0].value = "bar"    # <a>bar</a>
    #   e[0].value = "<a>"    # <a>&lt;a&gt;</a>
    def value=( val )
      @string = val.gsub( LINE_ENDINGS, "\n" )
      clear_cache
      @raw = false
    end

    def wrap(string, width, addnewline=false)
      # Recursively wrap string at width.
      return string if string.length <= width
      place = string.rindex(' ', width) # Position in string with last ' ' before cutoff
      if addnewline
        "\n" + string[0,place] + "\n" + wrap(string[place+1..-1], width)
      else
        string[0,place] + "\n" + wrap(string[place+1..-1], width)
      end
    end

    def indent_text(string, level=1, style="\t", indentfirstline=true)
      Kernel.warn("#{self.class.name}#indent_text is deprecated. See REXML::Formatters", uplevel: 1)
      return string if level < 0

      new_string = +''
      string.each_line { |line|
        indent_string = style * level
        new_line = (indent_string + line).sub(/[\s]+$/,'')
        new_string << new_line
      }
      new_string.strip! unless indentfirstline
      new_string
    end

    # == DEPRECATED
    # See REXML::Formatters
    #
    def write( writer, indent=-1, transitive=false, ie_hack=false )
      Kernel.warn("#{self.class.name}#write is deprecated.  See REXML::Formatters", uplevel: 1)
      formatter = if indent > -1
          REXML::Formatters::Pretty.new( indent )
        else
          REXML::Formatters::Default.new
        end
      formatter.write( self, writer )
    end

    # FIXME
    # This probably won't work properly
    def xpath
      @parent.xpath + "/text()"
    end

    # Writes out text, substituting special characters beforehand.
    # +out+ A String, IO, or any other object supporting <<( String )
    # +input+ the text to substitute and the write out
    #
    #   z=utf8.unpack("U*")
    #   ascOut=""
    #   z.each{|r|
    #     if r <  0x100
    #       ascOut.concat(r.chr)
    #     else
    #       ascOut.concat(sprintf("&#x%x;", r))
    #     end
    #   }
    #   puts ascOut
    def write_with_substitution out, input
      copy = input.clone
      # Doing it like this rather than in a loop improves the speed
      copy.gsub!( SPECIALS[0], SUBSTITUTES[0] )
      copy.gsub!( SPECIALS[1], SUBSTITUTES[1] )
      copy.gsub!( SPECIALS[2], SUBSTITUTES[2] )
      copy.gsub!( SPECIALS[3], SUBSTITUTES[3] )
      copy.gsub!( SPECIALS[4], SUBSTITUTES[4] )
      copy.gsub!( SPECIALS[5], SUBSTITUTES[5] )
      out << copy
    end

    private
    def clear_cache
      @normalized = nil
      @unnormalized = nil
    end

    # Reads text, substituting entities
    #
    # Deprecated since 3.4.5. Use Text.unnormalize instead.
    def Text::read_with_substitution( input, illegal=nil )
      Kernel.warn("#{name}.read_with_substitution is deprecated. " +
                  "Use #{name}.unnormalize instead.", uplevel: 1)
      copy = input.to_s
      if illegal and copy =~ illegal
        raise ParseException.new( "malformed text: Illegal character #$& in \"#{copy}\"" )
      end
      unnormalize(copy)
    end

    EREFERENCE = /&(?!#{Entity::NAME};)/

    # Returns the XML version declared by +document+'s XML declaration,
    # or nil when +document+ is nil or has no XML declaration.  Unlike
    # Document#version, this never modifies +document+.
    def Text.declared_xml_version(document)
      return nil unless document
      declaration = document[0]
      declaration.version if declaration.kind_of?(XMLDecl)
    end

    # Normalizes the line endings in +string+ to "\n".  When
    # +xml_version+ is "1.1", NEL (U+0085) and LS (U+2028) are
    # recognized as line endings in addition to "\r\n" and "\r".
    def Text.normalize_line_endings(string, xml_version=nil)
      if xml_version == "1.1"
        string.gsub(LINE_ENDINGS_XML_1_1, "\n")
      else
        string.gsub(LINE_ENDINGS, "\n")
      end
    end

    # Escapes all possible entities
    def Text::normalize( input, doctype=nil, entity_filter=nil )
      copy = input.to_s
      # Doing it like this rather than in a loop improves the speed
      #copy = copy.gsub( EREFERENCE, '&amp;' )
      copy = copy.gsub( "&", "&amp;" ) if copy.include?("&")
      if doctype
        # Replace all ampersands that aren't part of an entity
        doctype.entities.each_value do |entity|
          # Skip an empty value because String#gsub("") matches at every position
          next if entity.value.nil? or entity.value.empty?
          next if entity_filter and entity_filter.include?(entity.name)
          copy = copy.gsub( entity.value, "&#{entity.name};" )
        end
      else
        # Replace all ampersands that aren't part of an entity
        DocType::DEFAULT_ENTITIES.each_value do |entity|
          if copy.include?(entity.value)
            copy = copy.gsub(entity.value, "&#{entity.name};" )
          end
        end
      end
      copy
    end

    # Unescapes all possible entities
    def Text::unnormalize( string, doctype=nil, filter=nil, illegal=nil, entity_expansion_text_limit: nil, expanding: nil, xml_version: nil )
      entity_expansion_text_limit ||= Security.entity_expansion_text_limit
      sum = 0
      Text.normalize_line_endings(string, xml_version).gsub( REFERENCE ) {
        s = Text.expand($&, doctype, filter, expanding: expanding,
                        xml_version: xml_version)
        if sum + s.bytesize > entity_expansion_text_limit
          raise "entity expansion has grown too large"
        else
          sum += s.bytesize
        end
        s
      }
    end

    # Expands a numeric character reference's code point to a String.
    # Code points that are not valid XML characters are rejected, matching
    # the validation Text.check applies to literal references. This keeps the
    # entity-expansion path from emitting XML-forbidden characters (NUL,
    # control chars, U+FFFE/U+FFFF, code points beyond U+10FFFF, ...).
    # When +xml_version+ is "1.1", the wider XML 1.1 character range is
    # used instead, so that references to restricted characters such as
    # &#xB; are accepted.
    def Text.expand_character_reference(code_point, reference, xml_version: nil)
      valid_char = (xml_version == "1.1") ? VALID_CHAR_XML_1_1 : VALID_CHAR
      case code_point
      when *valid_char
        [code_point].pack('U*')
      else
        raise ParseException.new("Illegal character reference: <#{reference}>")
      end
    end

    def Text.expand(ref, doctype, filter, expanding: nil, xml_version: nil)
      if ref[1] == ?#
        if ref[2] == ?x
          expand_character_reference(ref[3...-1].to_i(16), ref,
                                     xml_version: xml_version)
        else
          expand_character_reference(ref[2...-1].to_i, ref,
                                     xml_version: xml_version)
        end
      elsif ref == '&amp;'
        '&'
      elsif filter and filter.include?( ref[1...-1] )
        ref
      elsif doctype
        doctype.entity( ref[1...-1], expanding: expanding ) or ref
      else
        entity_value = DocType::DEFAULT_ENTITIES[ ref[1...-1] ]
        entity_value ? entity_value.value : ref
      end
    end
  end
end
