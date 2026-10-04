# frozen_string_literal: true
require_relative "parent"
require_relative "parseexception"
require_relative "namespace"
require_relative 'entity'
require_relative 'attlistdecl'
require_relative 'xmltokens'
require_relative 'validation/dtd'
require 'strscan'

module REXML
  class ReferenceWriter
    def initialize(id_type,
                   public_id_literal,
                   system_literal,
                   context=nil)
      @id_type = id_type
      @public_id_literal = public_id_literal
      @system_literal = system_literal
      if context and context[:prologue_quote] == :apostrophe
        @default_quote = "'"
      else
        @default_quote = "\""
      end
    end

    def write(output)
      output << " #{@id_type}"
      if @public_id_literal
        if @public_id_literal.include?("'")
          quote = "\""
        else
          quote = @default_quote
        end
        output << " #{quote}#{@public_id_literal}#{quote}"
      end
      if @system_literal
        if @system_literal.include?("'")
          quote = "\""
        elsif @system_literal.include?("\"")
          quote = "'"
        else
          quote = @default_quote
        end
        output << " #{quote}#{@system_literal}#{quote}"
      end
    end
  end

  # Represents an XML DOCTYPE declaration; that is, the contents of <!DOCTYPE
  # ... >.  DOCTYPES can be used to declare the DTD of a document, as well as
  # being used to declare entities used in the document.
  class DocType < Parent
    include XMLTokens
    START = "<!DOCTYPE"
    STOP = ">"
    SYSTEM = "SYSTEM"
    PUBLIC = "PUBLIC"
    DEFAULT_ENTITIES = {
      'gt'=>EntityConst::GT,
      'lt'=>EntityConst::LT,
      'quot'=>EntityConst::QUOT,
      "apos"=>EntityConst::APOS
    }.freeze

    # name is the name of the doctype
    # external_id is the referenced DTD, if given
    attr_reader :name, :external_id, :entities, :namespaces

    # Constructor
    #
    #   dt = DocType.new( 'foo', '-//I/Hate/External/IDs' )
    #   # <!DOCTYPE foo '-//I/Hate/External/IDs'>
    #   dt = DocType.new( doctype_to_clone )
    #   # Incomplete.  Shallow clone of doctype
    #
    # +Note+ that the constructor:
    #
    #  Doctype.new( Source.new( "<!DOCTYPE foo 'bar'>" ) )
    #
    # is _deprecated_.  Do not use it.  It will probably disappear.
    def initialize( first, parent=nil )
      @entities = DEFAULT_ENTITIES
      @long_name = @uri = nil
      if first.kind_of? String
        super()
        @name = first
        @external_id = parent
      elsif first.kind_of? DocType
        super( parent )
        @name = first.name
        @external_id = first.external_id
        @long_name = first.instance_variable_get(:@long_name)
        @uri = first.instance_variable_get(:@uri)
      elsif first.kind_of? Array
        super( parent )
        @name = first[0]
        @external_id = first[1]
        @long_name = first[2]
        @uri = first[3]
      elsif first.kind_of? Source
        super( parent )
        parser = Parsers::BaseParser.new( first )
        event = parser.pull
        if event[0] == :start_doctype
          @name, @external_id, @long_name, @uri, = event[1..-1]
        end
      else
        super()
      end
    end

    def node_type
      :doctype
    end

    def attributes_of element
      (attribute_declarations[element] || {}).map do |name, definition|
        Attribute.new(name, definition.default) unless definition.default.nil?
      end
      .compact
    end

    def attribute_of element, attribute
      attribute_declarations[element]&.[](attribute)&.default
    end

    def element_declarations
      @element_declarations ||= grep(ElementDecl).each_with_object({}) do |declaration, mapping|
        mapping[declaration.name] ||= declaration
      end
    end

    def attribute_declarations
      @attribute_declarations ||= grep(AttlistDecl).each_with_object({}) do |declaration, mapping|
        element_mapping = mapping[declaration.element_name] ||= {}
        declaration.definitions.each do |definition|
          element_mapping[definition.name] ||= definition
        end
      end
    end

    def _attlist_mappings # :nodoc:
      attribute_declarations.each_with_object({}) do |(element, definitions), mapping|
        mapping[element] = definitions.each_with_object({}) do |(name, definition), attributes|
          attributes[name] = definition.default
        end
      end
    end

    def apply_default_attributes(element = nil)
      element ||= parent.root if parent.is_a?(Document)
      return self if element.nil?

      if element.is_a?(Element)
        definitions = attribute_declarations[element.expanded_name]
        definitions&.each do |name, definition|
          next if definition.default.nil?
          next if element.attributes.key?(name)

          element.attributes << Attribute.new(name, definition.default, element)
        end
        element.children.grep(Element).each do |child|
          apply_default_attributes(child)
        end
      end
      self
    end

    alias add_default_attributes apply_default_attributes

    def clone
      DocType.new self
    end

    # output::
    #   Where to write the string
    # indent::
    #   An integer.  If -1, no indentation will be used; otherwise, the
    #   indentation will be this number of spaces, and children will be
    #   indented an additional amount.
    # transitive::
    #   Ignored
    # ie_hack::
    #   Ignored
    def write( output, indent=0, transitive=false, ie_hack=false )
      f = REXML::Formatters::Default.new
      indent( output, indent )
      output << START
      output << ' '
      output << @name
      if @external_id
        reference_writer = ReferenceWriter.new(@external_id,
                                               @long_name,
                                               @uri,
                                               context)
        reference_writer.write(output)
      end
      unless @children.empty?
        output << ' ['
        @children.each { |child|
          output << "\n"
          f.write( child, output )
        }
        output << "\n]"
      end
      output << STOP
    end

    def context
      @parent&.context
    end

    def entity( name, expanding: nil )
      @entities[name]&.unnormalized(expanding: expanding)
    end

    def add child
      super(child)
      @entities = DEFAULT_ENTITIES.dup if @entities == DEFAULT_ENTITIES
      @entities[ child.name ] = child if child.kind_of? Entity
    end

    # This method retrieves the public identifier identifying the document's
    # DTD.
    #
    # Method contributed by Henrik Martensson
    def public
      case @external_id
      when "SYSTEM"
        nil
      when "PUBLIC"
        @long_name
      end
    end

    # This method retrieves the system identifier identifying the document's DTD
    #
    # Method contributed by Henrik Martensson
    def system
      case @external_id
      when "SYSTEM"
        @long_name
      when "PUBLIC"
        @uri.kind_of?(String) ? @uri : nil
      end
    end

    # This method returns a list of notations that have been declared in the
    # _internal_ DTD subset. Notations in the external DTD subset are not
    # listed.
    #
    # Method contributed by Henrik Martensson
    def notations
      children().select {|node| node.kind_of?(REXML::NotationDecl)}
    end

    # Retrieves a named notation. Only notations declared in the internal
    # DTD subset can be retrieved.
    #
    # Method contributed by Henrik Martensson
    def notation(name)
      notations.find { |notation_decl|
        notation_decl.name == name
      }
    end
  end

  # We don't really handle any of these since we're not a validating
  # parser, so we can be pretty dumb about them.  All we need to be able
  # to do is spew them back out on a write()

  # This is an abstract class.  You never use this directly; it serves as a
  # parent class for the specific declarations.
  class Declaration < Child
    def initialize src
      super()
      @string = src
    end

    def to_s
      @string+'>'
    end

    # == DEPRECATED
    # See REXML::Formatters
    #
    def write( output, indent )
      output << to_s
    end
  end

  public
  class ElementDecl < Declaration
    include XMLTokens

    attr_reader :name, :content_model

    def initialize( src )
      super
      scanner = StringScanner.new(src.to_s)
      scanner.scan(/\A\s*<!ELEMENT\s+/um) or
        raise ParseException.new("Malformed element declaration: #{src}")
      @name = scanner.scan(/\G#{NAME_STR}/ou)
      raise ParseException.new("Malformed element declaration: #{src}") if @name.nil?
      @content_model = parse_content_model(scanner, src)
    end

    def to_s
      @string.end_with?(">") ? @string : super
    end

    private

    def parse_content_model(scanner, source)
      scanner.skip(/\s+/um)
      model = if scanner.scan(/\GEMPTY\b/um)
                :empty
              elsif scanner.scan(/\GANY\b/um)
                :any
              elsif scanner.match?(/\G\(/um)
                parse_content_particle(scanner, source)
              else
                raise ParseException.new("Malformed element declaration: #{source}")
              end
      scanner.skip(/\s*/um)
      scanner.scan(/\G>/um)
      unless scanner.eos?
        raise ParseException.new("Malformed element declaration: #{source}")
      end
      model
    end

    def parse_content_particle(scanner, source)
      unless scanner.scan(/\G\(\s*/um)
        raise ParseException.new("Malformed element declaration: #{source}")
      end

      if scanner.scan(/\G#PCDATA/um)
        names = []
        loop do
          scanner.skip(/\s*/um)
          if scanner.scan(/\G\)/um)
            repeated = !scanner.scan(/\G\*/um).nil?
            unless repeated || names.empty?
              raise ParseException.new("Malformed element declaration: #{source}")
            end
            return [:mixed, names, repeated]
          elsif scanner.scan(/\G\|/um)
            scanner.skip(/\s*/um)
            name = scanner.scan(/\G#{NAME_STR}/ou)
            raise ParseException.new("Malformed element declaration: #{source}") if name.nil?
            names << name
          else
            raise ParseException.new("Malformed element declaration: #{source}")
          end
        end
      end

      children = [parse_content_term(scanner, source)]
      connector = nil
      loop do
        scanner.skip(/\s*/um)
        if scanner.scan(/\G\)/um)
          occurrence = parse_occurrence(scanner)
          kind = connector == "|" ? :choice : :sequence
          return [kind, children, occurrence]
        end

        scanned_connector = scanner.scan(/\G[,|]/um)
        raise ParseException.new("Malformed element declaration: #{source}") if scanned_connector.nil?
        if connector && connector != scanned_connector
          raise ParseException.new("Malformed element declaration: #{source}")
        end
        connector = scanned_connector
        scanner.skip(/\s*/um)
        children << parse_content_term(scanner, source)
      end
    end

    def parse_content_term(scanner, source)
      if scanner.match?(/\G\(/um)
        parse_content_particle(scanner, source)
      else
        name = scanner.scan(/\G#{NAME_STR}/ou)
        raise ParseException.new("Malformed element declaration: #{source}") if name.nil?
        [:element, name, parse_occurrence(scanner)]
      end
    end

    def parse_occurrence(scanner)
      case scanner.scan(/\G[?*+]/um)
      when "?"
        :optional
      when "*"
        :zero_or_more
      when "+"
        :one_or_more
      else
        :once
      end
    end
  end

  class ExternalEntity < Child
    def initialize( src )
      super()
      @entity = src
    end
    def to_s
      @entity
    end
    def write( output, indent )
      output << @entity
    end
  end

  class NotationDecl < Child
    attr_accessor :public, :system
    def initialize name, middle, pub, sys
      super(nil)
      @name = name
      @middle = middle
      @public = pub
      @system = sys
    end

    def to_s
      context = parent&.context
      notation = +"<!NOTATION #{@name}"
      reference_writer = ReferenceWriter.new(@middle, @public, @system, context)
      reference_writer.write(notation)
      notation << ">"
      notation
    end

    def write( output, indent=-1 )
      output << to_s
    end

    # This method retrieves the name of the notation.
    #
    # Method contributed by Henrik Martensson
    def name
      @name
    end
  end
end
