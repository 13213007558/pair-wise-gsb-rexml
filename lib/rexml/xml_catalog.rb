# frozen_string_literal: true

require "uri"

require_relative "document"

module REXML
  # = REXML::XMLCatalog
  #
  # An implementation of the lookup semantics of
  # {OASIS XML Catalogs 1.1}[https://www.oasis-open.org/committees/download.php/14809/xml-catalogs.html].
  #
  # An XML catalog maps external identifiers (system identifiers, public
  # identifiers and URIs) to other URIs, typically local mirrors.  This is
  # useful when parsing documents in an offline environment: DTDs and
  # entity references that point to the network can be redirected to
  # trusted local copies.
  #
  # The resolver never performs any I/O itself.  It only computes a
  # resolution *plan* (a Resolution object) that tells the caller which
  # URI a reference maps to.  Whether the resolved URI may actually be
  # read is decided by the caller's own policy, so a catalog can never
  # widen file or network access on its own:
  #
  #   resolver = REXML::XMLCatalog::Resolver.new
  #   resolver.add_catalog(catalog_xml, base_uri: "file:///mirror/catalog.xml")
  #   plan = resolver.resolve_system("http://example.com/legacy.dtd")
  #   # => #<REXML::XMLCatalog::Resolution uri="file:///mirror/legacy.dtd" ...>
  #
  # To plug the resolver into REXML's parser as the optional
  # +:entity_resolver+ document context entry, build an EntityResolver
  # with a policy block.  The block receives the resolution plan and
  # returns the replacement content (String or IO), or +nil+ to forbid
  # access to that resource:
  #
  #   entity_resolver = resolver.entity_resolver do |plan|
  #     plan.uri.start_with?("file:///mirror/") ? File.read(plan.uri) : nil
  #   end
  #   document = REXML::Document.new(xml, entity_resolver: entity_resolver)
  #
  # Supported catalog entries: +system+, +public+, +uri+,
  # +rewriteSystem+, +rewriteURI+, +systemSuffix+, +uriSuffix+,
  # +delegateSystem+, +delegatePublic+, +delegateURI+, +nextCatalog+ and
  # +group+.  The +prefer+ attribute is honored on the root +catalog+
  # element (it decides whether public or system entries are consulted
  # first when both identifiers are known); +prefer+ on +group+ elements
  # is currently ignored.  Relative URI references in +uri+,
  # +rewritePrefix+ and +catalog+ attributes are resolved against the
  # in-scope +xml:base+ (or the catalog's own base URI).
  #
  # Delegate and +nextCatalog+ catalogs are loaded lazily through the
  # loader callback given to Resolver.new.  Without a loader, delegated
  # catalogs are simply unreachable and resolution continues with the
  # remaining entries.  A delegate catalog that fails to load or parse
  # is skipped as if it did not exist; it never causes the original
  # identifier to be returned as if it were resolved.  Circular
  # delegation raises CircularDelegationError, which reports the chain
  # of catalogs that forms the loop.
  module XMLCatalog
    # Base class for errors raised by this module.
    class Error < StandardError
    end

    # Raised when catalog delegation forms a cycle.  #path lists the
    # catalogs (by base URI, or "memory:<id>" for anonymous in-memory
    # catalogs) in the order they were entered, ending with the catalog
    # that closes the loop.
    class CircularDelegationError < Error
      attr_reader :path

      def initialize(path)
        @path = path.freeze
        super("Circular XML catalog delegation detected: #{path.join(' -> ')}")
      end
    end

    # The result of a successful resolution: a plan describing which URI
    # a reference maps to and how the mapping was found.  A plan carries
    # no content; reading the resource it points to is a separate
    # decision owned by the caller.
    class Resolution
      # The final mapped URI (relative references already resolved
      # against the in-scope base).
      attr_reader :uri
      # The kind of catalog entry that produced the mapping, one of
      # :system, :public, :uri, :rewrite_system, :rewrite_uri,
      # :system_suffix or :uri_suffix.
      attr_reader :entry_type
      # The identifier string that was looked up.
      attr_reader :matched
      # The chain of catalogs consulted to reach the match, in order.
      attr_reader :catalogs
      def initialize(uri:, entry_type:, matched:, catalogs:)
        @uri = uri
        @entry_type = entry_type
        @matched = matched
        @catalogs = catalogs.freeze
      end

      def to_s
        @uri
      end
    end

    # A parsed XML catalog: an ordered list of entries plus the
    # catalog-level +prefer+ and base URI.
    class Catalog
      NAMESPACE_URI = "urn:oasis:names:tc:entity:xmlns:xml:catalog"

      DEFAULT_PREFER = "public"

      # kind::  one of :system, :public, :uri, :rewrite_system,
      #         :rewrite_uri, :system_suffix, :uri_suffix,
      #         :delegate_system, :delegate_public, :delegate_uri or
      #         :next_catalog
      # key::   the string matched against the identifier (nil for
      #         :next_catalog)
      # value:: the target URI (already resolved against the in-scope
      #         base)
      Entry = Struct.new(:kind, :key, :value)

      attr_reader :entries, :prefer, :base_uri

      def initialize(entries: [], prefer: DEFAULT_PREFER, base_uri: nil)
        @entries = entries
        @prefer = prefer
        @base_uri = base_uri
      end

      # Parses +source+ (an XML String, an IO, or a REXML::Document)
      # into a Catalog.  +base_uri+ is the catalog's own URI, used to
      # resolve relative references when no xml:base applies.
      def self.parse(source, base_uri: nil)
        document = source.is_a?(REXML::Document) ? source : REXML::Document.new(source)
        root = document.root
        unless root and root.name == "catalog"
          raise Error, "XML catalog must have a 'catalog' root element"
        end
        base = expand_base(root, base_uri)
        prefer = root.attributes["prefer"] || DEFAULT_PREFER
        unless ["system", "public"].include?(prefer)
          raise Error, "Invalid prefer value #{prefer.inspect}: expected \"system\" or \"public\""
        end
        entries = []
        collect_entries(root, entries, base)
        new(entries: entries, prefer: prefer, base_uri: base)
      end

      # Normalizes a public identifier per the XML Catalogs spec: runs
      # of whitespace collapse to a single space and surrounding
      # whitespace is removed.
      def self.normalize_public_id(public_id)
        public_id.gsub(/[ \t\r\n]+/, " ").strip
      end

      # Resolves +reference+ against +base+ (RFC 3986).  Returns the
      # reference unchanged when no base is known or when either side
      # cannot be parsed as a URI.
      def self.resolve_reference(reference, base)
        return reference if base.nil? or base.empty?
        URI.join(base, reference).to_s
      rescue URI::Error
        reference
      end

      # :nodoc:
      def self.expand_base(element, base)
        xml_base = element.attributes["xml:base"]
        return base if xml_base.nil? or xml_base.empty?
        resolve_reference(xml_base, base)
      end

      ENTRY_DEFINITIONS = {
        "system"         => [:system,          "systemId",            "uri",           false],
        "public"         => [:public,          "publicId",            "uri",           true],
        "uri"            => [:uri,             "name",                "uri",           false],
        "rewriteSystem"  => [:rewrite_system,  "systemIdStartString", "rewritePrefix", false],
        "rewriteURI"     => [:rewrite_uri,     "uriStartString",      "rewritePrefix", false],
        "systemSuffix"   => [:system_suffix,   "systemSuffix",        "uri",           false],
        "uriSuffix"      => [:uri_suffix,      "uriSuffix",           "uri",           false],
        "delegateSystem" => [:delegate_system, "systemIdStartString", "catalog",       false],
        "delegatePublic" => [:delegate_public, "publicIdStartString", "catalog",       true],
        "delegateURI"    => [:delegate_uri,    "uriStartString",      "catalog",       false],
        "nextCatalog"    => [:next_catalog,    nil,                   "catalog",       false],
      }.freeze
      private_constant :ENTRY_DEFINITIONS

      # :nodoc:
      def self.collect_entries(parent, entries, base)
        parent.elements.each do |element|
          if element.name == "group"
            collect_entries(element, entries, expand_base(element, base))
            next
          end
          definition = ENTRY_DEFINITIONS[element.name]
          next unless definition
          kind, key_attribute, value_attribute, normalize = definition
          element_base = expand_base(element, base)
          key = nil
          if key_attribute
            key = element.attributes[key_attribute]
            if key.nil?
              raise Error, "Missing required attribute #{key_attribute.inspect} " \
                           "in <#{element.name}> entry"
            end
            key = normalize_public_id(key) if normalize
          end
          value = element.attributes[value_attribute]
          if value.nil?
            raise Error, "Missing required attribute #{value_attribute.inspect} " \
                         "in <#{element.name}> entry"
          end
          entries << Entry.new(kind, key, resolve_reference(value, element_base))
        end
        entries
      end
      private_class_method :collect_entries, :expand_base
    end

    # Resolves identifiers against an ordered list of catalogs,
    # following delegation and +nextCatalog+ chains.  All lookups are
    # pure: the resolver only returns Resolution plans and never reads
    # the resources those plans point to.
    class Resolver
      attr_reader :catalogs

      # +loader+ is an optional callable invoked with a catalog URI
      # (String) when a delegate or +nextCatalog+ catalog needs to be
      # read.  It must return the catalog source (XML String, IO,
      # REXML::Document or XMLCatalog::Catalog), or nil when the catalog
      # is unavailable.  Without a loader, delegated catalogs are
      # unreachable and simply skipped.
      def initialize(loader: nil)
        @loader = loader
        @catalogs = []
        @catalog_cache = {}
      end

      # Adds a root catalog.  +source+ may be an XMLCatalog::Catalog, an
      # XML String, an IO or a REXML::Document.  +base_uri+ is the
      # catalog's own URI, used for relative references and cycle
      # detection.  Returns the Catalog.
      def add_catalog(source, base_uri: nil)
        catalog = source.is_a?(Catalog) ? source : Catalog.parse(source, base_uri: base_uri)
        @catalogs << catalog
        catalog
      end

      # Resolves a system identifier.  Returns a Resolution or nil.
      def resolve_system(system_id)
        resolve_with_mode(:system, system_id)
      end

      # Resolves a public identifier (normalized before matching).
      # Returns a Resolution or nil.
      def resolve_public(public_id)
        return nil if public_id.nil?
        resolve_with_mode(:public, Catalog.normalize_public_id(public_id))
      end

      # Resolves a URI reference.  Returns a Resolution or nil.
      def resolve_uri(uri)
        resolve_with_mode(:uri, uri)
      end

      # Resolves an external identifier.  When both identifiers are
      # given, the root catalog's +prefer+ decides which one is tried
      # first: with prefer="public" (the default) public entries win,
      # with prefer="system" system entries win.  Falls back to the
      # other identifier when the preferred lookup finds nothing.
      def resolve(system_id: nil, public_id: nil)
        prefer = @catalogs.first ? @catalogs.first.prefer : Catalog::DEFAULT_PREFER
        modes = []
        if prefer == "system"
          modes << :system if system_id
          modes << :public if public_id
        else
          modes << :public if public_id
          modes << :system if system_id
        end
        modes.each do |mode|
          resolution =
            if mode == :system
              resolve_system(system_id)
            else
              resolve_public(public_id)
            end
          return resolution if resolution
        end
        nil
      end

      # Builds an EntityResolver that combines this resolver's plans
      # with a caller-supplied access policy.  The policy block receives
      # the Resolution plan and must return the resource content
      # (String or IO) or nil to forbid access.
      def entity_resolver(&policy)
        unless policy
          raise ArgumentError, "a policy block is required to build an entity resolver"
        end
        EntityResolver.new(self, &policy)
      end

      private

      LOCAL_MATCH_ORDER = {
        system: [[:system, :exact], [:rewrite_system, :prefix], [:system_suffix, :suffix]],
        public: [[:public, :exact]],
        uri:    [[:uri, :exact], [:rewrite_uri, :prefix], [:uri_suffix, :suffix]],
      }.freeze

      DELEGATE_KIND = {
        system: :delegate_system,
        public: :delegate_public,
        uri:    :delegate_uri,
      }.freeze

      def resolve_with_mode(mode, input)
        return nil if input.nil?
        @catalogs.each do |catalog|
          resolution = resolve_in(catalog, mode, input, [])
          return resolution if resolution
        end
        nil
      end

      def resolve_in(catalog, mode, input, trail)
        trail = enter_catalog(catalog, trail)

        entry = find_local_entry(catalog, mode, input)
        return build_plan(entry, input, trail) if entry

        delegate_kind = DELEGATE_KIND.fetch(mode)
        delegates = catalog.entries.select do |candidate|
          candidate.kind == delegate_kind and input.start_with?(candidate.key)
        end
        delegates.sort_by.with_index do |candidate, index|
          [-candidate.key.length, index]
        end.each do |delegate|
          delegate_catalog = load_catalog(delegate.value)
          next unless delegate_catalog
          resolution = resolve_in(delegate_catalog, mode, input, trail)
          return resolution if resolution
        end

        catalog.entries.each do |candidate|
          next unless candidate.kind == :next_catalog
          next_catalog = load_catalog(candidate.value)
          next unless next_catalog
          resolution = resolve_in(next_catalog, mode, input, trail)
          return resolution if resolution
        end

        nil
      end

      def find_local_entry(catalog, mode, input)
        LOCAL_MATCH_ORDER.fetch(mode).each do |kind, match|
          entries = catalog.entries.select { |candidate| candidate.kind == kind }
          entry =
            case match
            when :exact
              entries.find { |candidate| candidate.key == input }
            when :prefix
              entries.select { |candidate| input.start_with?(candidate.key) }
                     .max_by { |candidate| candidate.key.length }
            when :suffix
              entries.select { |candidate| input.end_with?(candidate.key) }
                     .max_by { |candidate| candidate.key.length }
            end
          return entry if entry
        end
        nil
      end

      def build_plan(entry, input, trail)
        uri =
          case entry.kind
          when :rewrite_system, :rewrite_uri
            entry.value + input[entry.key.length..]
          else
            entry.value
          end
        Resolution.new(uri: uri,
                       entry_type: entry.kind,
                       matched: input,
                       catalogs: trail)
      end

      def enter_catalog(catalog, trail)
        key = catalog.base_uri || "memory:#{catalog.object_id}"
        if trail.include?(key)
          raise CircularDelegationError.new(trail + [key])
        end
        trail + [key]
      end

      def load_catalog(uri)
        return @catalog_cache[uri] if @catalog_cache.key?(uri)
        catalog = nil
        if @loader
          source = @loader.call(uri)
          if source
            begin
              catalog = source.is_a?(Catalog) ? source : Catalog.parse(source, base_uri: uri)
            rescue REXML::ParseException, Error
              catalog = nil
            end
          end
        end
        @catalog_cache[uri] = catalog
      end
    end

    # Adapter between a Resolver and REXML's optional +:entity_resolver+
    # document context entry.  It turns identifiers into resolution
    # plans via the resolver, then asks the caller's policy whether the
    # planned resource may actually be read.
    class EntityResolver
      def initialize(resolver, &policy)
        @resolver = resolver
        @policy = policy
      end

      # Called by the parser with the external identifier of the
      # document's DTD.  Returns the replacement content (String or IO)
      # or nil when the reference must not be resolved.
      def resolve(system_id, public_id = nil)
        plan = @resolver.resolve(system_id: system_id, public_id: public_id)
        return nil unless plan
        @policy.call(plan)
      end
    end
  end
end

