# frozen_string_literal: false
#vim:ts=2 sw=2 noexpandtab:
require_relative 'child'
require_relative 'source'
require_relative 'xmltokens'
require 'strscan'

module REXML
  # This class needs:
  # * Documentation
  # * Work!  Not all types of attlists are intelligently parsed, so we just
  # spew back out what we get in.  This works, but it would be better if
  # we formatted the output ourselves.
  #
  # AttlistDecls provide *just* enough support to allow namespace
  # declarations.  If you need some sort of generalized support, or have an
  # interesting idea about how to map the hideous, terrible design of DTD
  # AttlistDecls onto an intuitive Ruby interface, let me know.  I'm desperate
  # for anything to make DTDs more palateable.
  class AttlistDecl < Child
    include Enumerable
    include XMLTokens

    # What is this?  Got me.
    attr_reader :element_name
    attr_reader :definitions

    # Create an AttlistDecl, pulling the information from a Source.  Notice
    # that this isn't very convenient; to create an AttlistDecl, you basically
    # have to format it yourself, and then have the initializer parse it.
    # Sorry, but for the foreseeable future, DTD support in REXML is pretty
    # weak on convenience.  Have I mentioned how much I hate DTDs?
    def initialize(source)
      super()
      if (source.kind_of? Array)
        @element_name, @pairs, @contents = *source
        @definitions = parse_definitions(@contents)
      end
    end

    # Access the attlist attribute/value pairs.
    #  value = attlist_decl[ attribute_name ]
    def [](key)
      @pairs[key]
    end

    # Whether an attlist declaration includes the given attribute definition
    #  if attlist_decl.include? "xmlns:foobar"
    def include?(key)
      @pairs.keys.include? key
    end

    # Iterate over the key/value pairs:
    #  attlist_decl.each { |attribute_name, attribute_value| ... }
    def each(&block)
      @pairs.each(&block)
    end

    # Write out exactly what we got in.
    def write out, indent=-1
      out << @contents
    end

    def node_type
      :attlistdecl
    end

    AttributeDefinition = Struct.new(:name, :type, :enumeration, :default,
                                    :required, :fixed, keyword_init: true)

    private

    def parse_definitions(source)
      scanner = StringScanner.new(source.to_s)
      scanner.scan(/\A\s*<!ATTLIST\s+/um) or
        raise ParseException.new("Malformed attribute list declaration: #{source}")
      element = scanner.scan(/\G#{NAME_STR}/ou)
      raise ParseException.new("Malformed attribute list declaration: #{source}") if element.nil?

      definitions = []
      until scanner.match?(/\G\s*>/um)
        scanner.skip(/\s+/um)
        name = scanner.scan(/\G#{NAME_STR}/ou)
        raise ParseException.new("Malformed attribute list declaration: #{source}") if name.nil?

        scanner.skip(/\s+/um)
        type, enumeration = parse_attribute_type(scanner, source)
        required, fixed, default = parse_default_declaration(scanner, source)
        definitions << AttributeDefinition.new(name: name,
                                               type: type,
                                               enumeration: enumeration,
                                               default: default,
                                               required: required,
                                               fixed: fixed)
      end

      scanner.scan(/\G\s*>/um)
      raise ParseException.new("Malformed attribute list declaration: #{source}") unless scanner.eos?
      definitions
    end

    def parse_attribute_type(scanner, source)
      if scanner.scan(/\GNOTATION(?=\s*\()/um)
        parse_enumerated_type(scanner, source, "NOTATION")
      elsif scanner.match?(/\G\(/um)
        parse_enumerated_type(scanner, source, nil)
      else
        type = scanner.scan(/\G(?:CDATA|IDREFS?|ENTITIES|NMTOKENS)/u)
        type ||= scanner.scan(/\G(?:ENTITY|NMTOKEN|ID)/u)
        raise ParseException.new("Malformed attribute list declaration: #{source}") if type.nil?
        [type, nil]
      end
    end

    def parse_enumerated_type(scanner, source, type)
      scanner.skip(/\s*/um)
      raise ParseException.new("Malformed attribute list declaration: #{source}") unless scanner.scan(/\G\(/um)
      values = []
      loop do
        scanner.skip(/\s*/um)
        value = scanner.scan(/\G#{NMTOKEN}/ou)
        raise ParseException.new("Malformed attribute list declaration: #{source}") if value.nil?
        values << value
        scanner.skip(/\s*/um)
        if scanner.scan(/\G\)/um)
          break
        end
        raise ParseException.new("Malformed attribute list declaration: #{source}") unless scanner.scan(/\G\s*\|\s*/um)
      end
      [type || "ENUMERATION", values]
    end

    def parse_default_declaration(scanner, source)
      scanner.skip(/\s+/um)
      if scanner.scan(/\G#REQUIRED/um)
        [true, false, nil]
      elsif scanner.scan(/\G#IMPLIED/um)
        [false, false, nil]
      else
        fixed = !scanner.scan(/\G#FIXED(?=\s)/um).nil?
        scanner.skip(/\s+/um) if fixed
        value = parse_quoted_value(scanner, source)
        [false, fixed, value]
      end
    end

    def parse_quoted_value(scanner, source)
      quote = scanner.scan(/\G["']/um)
      raise ParseException.new("Malformed attribute list declaration: #{source}") if quote.nil?
      quoted_character = Regexp.escape(quote)
      value = scanner.scan(/\G(?:[^<&#{quoted_character}]|&#{NAME_STR};|&#\d+;|&#x[0-9a-fA-F]+;)*/ou)
      raise ParseException.new("Malformed attribute list declaration: #{source}") unless scanner.scan(/\G#{Regexp.escape(quote)}/um)
      value
    end
  end
end
