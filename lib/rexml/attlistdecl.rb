# frozen_string_literal: false
#vim:ts=2 sw=2 noexpandtab:
require_relative 'child'
require_relative 'source'
require 'strscan'
require_relative 'xmltokens'

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
    attr_reader :attribute_definitions

    # Create an AttlistDecl, pulling the information from a Source.  Notice
    # that this isn't very convenient; to create an AttlistDecl, you basically
    # have to format it yourself, and then have the initializer parse it.
    # Sorry, but for the foreseeable future, DTD support in REXML is pretty
    # weak on convenience.  Have I mentioned how much I hate DTDs?
    def initialize(source)
      super()
      if (source.kind_of? Array)
        @element_name, @pairs, @contents = *source
        @attribute_definitions = self.class.parse_attribute_definitions(@contents)
        @attribute_definitions.each do |definition|
          definition.attlist_declaration = self
        end
      end
    end

    AttributeDefinition = Struct.new(:name, :type, :enumeration, :presence,
                                     :default, :fixed, :attlist_declaration,
                                     keyword_init: true)

    def self.parse_attribute_definitions(contents)
      scanner = StringScanner.new(contents.to_s)
      scanner.scan_until(/\A\s*<!ATTLIST/)
      scanner.skip(/\s+/)
      scanner.scan(/#{NAME_STR}/o)
      definitions = []
      until scanner.match?(/\s*>/)
        scanner.skip(/\s+/)
        name = scanner.scan(/#{NAME_STR}/o)
        break if name.nil?

        scanner.skip(/\s+/)
        type, enumeration = parse_attribute_type(scanner)
        scanner.skip(/\s+/)
        presence, fixed, default = parse_attribute_default(scanner)
        definitions << AttributeDefinition.new(
          name: name,
          type: type,
          enumeration: enumeration,
          presence: presence,
          default: default,
          fixed: fixed,
          attlist_declaration: nil
        )
      end
      definitions
    end

    def self.parse_attribute_type(scanner)
      if scanner.match?(/NOTATION\s+/)
        scanner.scan(/NOTATION\s+/)
        return ["NOTATION", parse_enumeration(scanner)]
      end

      if scanner.match?(/\(/)
        return [nil, parse_enumeration(scanner)]
      end

      type = scanner.scan(/CDATA|IDREFS|IDREF|ID|ENTITIES|ENTITY|NMTOKENS|NMTOKEN/)
      [type, nil]
    end
    private_class_method :parse_attribute_type

    def self.parse_enumeration(scanner)
      scanner.scan(/\s*\(\s*/)
      values = []
      loop do
        value = scanner.scan(/#{NAME_CHAR}*/o)
        values << value unless value.nil? || value.empty?
        scanner.skip(/\s*/)
        break unless scanner.scan(/\|/)
        scanner.skip(/\s*/)
      end
      scanner.scan(/\s*\)/)
      values
    end
    private_class_method :parse_enumeration

    def self.parse_attribute_default(scanner)
      if scanner.scan(/#REQUIRED/)
        [:required, false, nil]
      elsif scanner.scan(/#IMPLIED/)
        [:implied, false, nil]
      elsif scanner.scan(/#FIXED\s+/)
        [:default, true, parse_attribute_value(scanner)]
      else
        [:default, false, parse_attribute_value(scanner)]
      end
    end
    private_class_method :parse_attribute_default

    def self.parse_attribute_value(scanner)
      quote = scanner.scan(/["']/)
      value = scanner.scan_until(/#{quote == "'" ? "'" : '"'}/)
      value ? value[0...-1] : nil
    end
    private_class_method :parse_attribute_value

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
  end
end
