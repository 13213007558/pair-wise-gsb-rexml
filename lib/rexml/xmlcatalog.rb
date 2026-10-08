# frozen_string_literal: true

require "uri"

require_relative "document"

module REXML
  # REXML::XMLCatalog implements an
  # {OASIS XML Catalogs 1.1}[https://www.oasis-open.org/committees/download.php/14809/xml-catalogs.html]
  # resolver.
  #
  # An XML catalog maps external identifiers (system identifiers and
  # public identifiers) and general URI references to replacement URIs,
  # typically local mirrors.  This is useful when parsing legacy XML in
  # offline environments: DTDs and entity files referenced by well-known
  # or absolute URIs can be redirected to local copies.
  #
  # The resolver only produces a resolution _plan_ (a
  # XMLCatalog::Resolution object).  It never opens the mapped resource:
  # whether the resulting URI may actually be read, and how, is entirely
  # up to the caller's own policy.  Likewise, catalogs referenced through
  # +delegatePublic+, +delegateSystem+, +delegateURI+ or +nextCatalog+
  # entries are loaded only through the caller-supplied loader callback,
  # so a catalog can never widen file or network access on its own.
  #
  # Example:
  #
  #   catalogs = {"app:///sub.xml" => sub_catalog_xml}
  #   resolver = REXML::XMLCatalog::Resolver.new(
  #     loader: ->(catalog_uri) { catalogs[catalog_uri] }
  #   )
  #   resolver.add_catalog(catalog_xml, uri: "app:///catalog.xml")
  #   plan = resolver.resolve(system_id: "http://example.com/legacy.dtd")
  #   if plan && my_policy.allow?(plan.uri)
  #     read_resource(plan.uri)
  #   end
  module XMLCatalog
    # Namespace URI of OASIS XML catalog documents.
    CATALOG_NAMESPACE = "urn:oasis:names:tc:entity:xmlns:xml:catalog"

    # Base class for XML catalog errors.
    class Error < StandardError; end

    # Raised when a catalog document cannot be parsed or is not an
    # OASIS XML catalog.
    class ParseError < Error; end

    # Raised when catalog delegation (+delegatePublic+, +delegateSystem+,
    # +delegateURI+ or +nextCatalog+) forms a loop.  The chain of catalog
    # URIs that forms the loop is reported in the message and available
    # via #catalog_chain.
    class CircularDelegateError < Error
      attr_reader :catalog_chain

      def initialize(catalog_chain)
        @catalog_chain = catalog_chain.dup.freeze
        super("XML catalog delegation loop: #{catalog_chain.join(' -> ')}")
      end
    end

    # A resolution plan produced by Resolver.  It describes how an
    # identifier was mapped by the catalog; carrying out the plan (that
    # is, actually reading the resource) is left to the caller.
    class Resolution
      # The mapped URI.  Relative catalog entry URIs are made absolute
      # against the base URI in effect for the matching entry.
      attr_reader :uri

      # The kind of catalog entry that matched: +:system+, +:public+,
      # +:uri+, +:rewrite_system+, +:rewrite_uri+, +:system_suffix+ or
      # +:uri_suffix+.
      attr_reader :match

      # The identifier from the query that matched (a system identifier,
      # a public identifier or a URI reference).
      attr_reader :identifier

      # The URI of the catalog that contains the matching entry, or nil
      # if that catalog was added without a URI.
      attr_reader :catalog_uri

      # The URIs of the catalogs consulted to reach the match, from the
      # root catalog through any delegated catalogs.  Catalogs added
      # without a URI do not appear in the chain.
      attr_reader :catalog_chain

      def initialize(uri:, match:, identifier:, catalog_uri:, catalog_chain:)
        @uri = uri
        @match = match
        @identifier = identifier
        @catalog_uri = catalog_uri
        @catalog_chain = catalog_chain.freeze
      end

      def to_s
        "#<#{self.class.name} #{@match} #{@identifier.inspect} -> #{@uri.inspect}>"
      end
    end

    # Normalizes a public identifier as described by the XML Catalogs
    # specification: runs of white space (#x20, #x9, #xD, #xA) are
    # collapsed to a single space and leading/trailing white space is
    # removed.
    def self.normalize_public_id(public_id)
      public_id.gsub(/[\x20\x09\x0d\x0a]+/, " ").strip
    end

    # Resolves +reference+ against +base+ following RFC 3986.  Returns
    # +reference+ unchanged when +base+ is nil or is not an absolute URI.
    def self.absolutize(base, reference)
      return reference if base.nil? or reference.nil?
      URI.join(base, reference).to_s
    rescue URI::Error
      reference
    end

    # :stopdoc:
    Entry = Struct.new(:kind, :key, :value, :prefer)

    # A parsed catalog document.  Created by Resolver#add_catalog, or
    # internally when the loader callback supplies a delegated catalog.
    class Catalog
      attr_reader :uri, :next_catalogs,
                  :system_entries, :public_entries, :uri_entries,
                  :rewrite_system_entries, :rewrite_uri_entries,
                  :system_suffix_entries, :uri_suffix_entries,
                  :delegate_system_entries, :delegate_public_entries,
                  :delegate_uri_entries

      def initialize(uri)
        @uri = uri
        @system_entries = {}
        @public_entries = {}
        @uri_entries = {}
        @rewrite_system_entries = []
        @rewrite_uri_entries = []
        @system_suffix_entries = []
        @uri_suffix_entries = []
        @delegate_system_entries = []
        @delegate_public_entries = []
        @delegate_uri_entries = []
        @next_catalogs = []
      end
    end

    class Parser
      def parse(source, uri)
        document = source.kind_of?(REXML::Document) ? source : REXML::Document.new(source)
        root = document.root
        unless root and root.name == "catalog" and catalog_element?(root)
          raise ParseError, "not an OASIS XML catalog document"
        end
        catalog = Catalog.new(uri)
        base = scoped_base(uri, root)
        prefer = root.attributes["prefer"] || "public"
        collect(root, catalog, prefer, base)
        catalog
      rescue REXML::ParseException => exception
        raise ParseError, exception.message
      end

      private

      def catalog_element?(element)
        namespace = element.namespace
        namespace.nil? or namespace.empty? or namespace == CATALOG_NAMESPACE
      end

      def scoped_base(base, element)
        xml_base = element.attributes["xml:base"]
        xml_base ? XMLCatalog.absolutize(base, xml_base) : base
      end

      def collect(element, catalog, prefer, base)
        element.elements.each do |child|
          next unless catalog_element?(child)
          child_base = scoped_base(base, child)
          child_prefer = child.attributes["prefer"] || prefer
          case child.name
          when "group"
            collect(child, catalog, child_prefer, child_base)
          when "system"
            add_exact(catalog.system_entries, :system, child,
                      child_base, child_prefer, "systemId")
          when "public"
            public_id = child.attributes["publicId"]
            uri = child.attributes["uri"]
            if public_id and uri
              key = XMLCatalog.normalize_public_id(public_id)
              catalog.public_entries[key] ||=
                Entry.new(:public, key,
                          XMLCatalog.absolutize(child_base, uri),
                          child_prefer)
            end
          when "uri"
            add_exact(catalog.uri_entries, :uri, child,
                      child_base, child_prefer, "name")
          when "rewriteSystem"
            add_list(catalog.rewrite_system_entries, :rewrite_system, child,
                     child_base, child_prefer,
                     "systemIdStartString", "rewritePrefix")
          when "rewriteURI"
            add_list(catalog.rewrite_uri_entries, :rewrite_uri, child,
                     child_base, child_prefer,
                     "uriStartString", "rewritePrefix")
          when "systemSuffix"
            add_list(catalog.system_suffix_entries, :system_suffix, child,
                     child_base, child_prefer, "systemIdSuffix", "uri")
          when "uriSuffix"
            add_list(catalog.uri_suffix_entries, :uri_suffix, child,
                     child_base, child_prefer, "uriSuffix", "uri")
          when "delegateSystem"
            add_list(catalog.delegate_system_entries, :delegate_system, child,
                     child_base, child_prefer, "systemIdStartString", "catalog")
          when "delegatePublic"
            public_id_start = child.attributes["publicIdStartString"]
            ref = child.attributes["catalog"]
            if public_id_start and ref
              catalog.delegate_public_entries <<
                Entry.new(:delegate_public,
                          XMLCatalog.normalize_public_id(public_id_start),
                          XMLCatalog.absolutize(child_base, ref),
                          child_prefer)
            end
          when "delegateURI"
            add_list(catalog.delegate_uri_entries, :delegate_uri, child,
                     child_base, child_prefer, "uriStartString", "catalog")
          when "nextCatalog"
            ref = child.attributes["catalog"]
            catalog.next_catalogs << XMLCatalog.absolutize(child_base, ref) if ref
          end
        end
      end

      def add_exact(entries, kind, child, base, prefer, key_attribute)
        key = child.attributes[key_attribute]
        uri = child.attributes["uri"]
        return unless key and uri
        entries[key] ||=
          Entry.new(kind, key, XMLCatalog.absolutize(base, uri), prefer)
      end

      def add_list(entries, kind, child, base, prefer,
                   key_attribute, value_attribute)
        key = child.attributes[key_attribute]
        value = child.attributes[value_attribute]
        return unless key and value
        entries << Entry.new(kind, key, XMLCatalog.absolutize(base, value), prefer)
      end
    end
    # :startdoc:

    # Resolves external identifiers and URI references against a set of
    # OASIS XML catalogs.
    #
    # Root catalogs are registered with #add_catalog.  Catalogs
    # referenced by +delegatePublic+, +delegateSystem+, +delegateURI+ and
    # +nextCatalog+ entries are obtained through the +loader+ callback
    # given to the constructor; the callback receives the (absolutized)
    # catalog URI and must return the catalog document (a String, an IO
    # or a REXML::Document), or nil when the catalog is unavailable or
    # not allowed.  Without a +loader+, delegated catalogs are simply
    # treated as empty: the resolver never touches the file system or
    # the network by itself.
    #
    # Resolution methods return a XMLCatalog::Resolution plan, or nil
    # when no catalog entry matches.  Reading the resource identified by
    # the plan is the caller's responsibility and subject to the caller's
    # own policy.
    class Resolver
      # +loader+ is an optional callable used to fetch delegated and
      # next catalogs.  It is the only I/O the resolver ever performs.
      def initialize(loader: nil)
        @loader = loader
        @catalogs = []
        @loaded_catalogs = {}
      end

      # Parses +source+ (a String, an IO or a REXML::Document containing
      # an OASIS XML catalog) and registers it as a root catalog.
      # +uri+ is the catalog's own URI; relative URI references in the
      # catalog are resolved against it.  Root catalogs are consulted in
      # registration order.  Returns the parsed XMLCatalog::Catalog.
      #
      # Raises XMLCatalog::ParseError if +source+ is not a well-formed
      # catalog document.
      def add_catalog(source, uri: nil)
        catalog = Parser.new.parse(source, uri)
        @catalogs << catalog
        catalog
      end

      # Resolves an external identifier.  Returns a
      # XMLCatalog::Resolution, or nil when no entry matches.
      #
      # Matching follows the XML Catalogs specification: exact +system+
      # entries first, then exact +public+ entries (unless +prefer+ is
      # "system" and a system identifier was given), then
      # +rewriteSystem+, +systemSuffix+, +delegatePublic+,
      # +delegateSystem+ and finally +nextCatalog+ entries.
      def resolve(system_id: nil, public_id: nil)
        return nil if system_id.nil? and public_id.nil?
        @catalogs.each do |catalog|
          plan = resolve_external(catalog, system_id, public_id,
                                  root_chain(catalog))
          return plan if plan
        end
        nil
      end

      # Resolves a system identifier alone.  Equivalent to
      # <tt>resolve(system_id: system_id)</tt>.
      def resolve_system(system_id)
        resolve(system_id: system_id)
      end

      # Resolves a public identifier alone.  Equivalent to
      # <tt>resolve(public_id: public_id)</tt>.
      def resolve_public(public_id)
        resolve(public_id: public_id)
      end

      # Resolves a general URI reference through +uri+, +rewriteURI+,
      # +uriSuffix+, +delegateURI+ and +nextCatalog+ entries.  Returns a
      # XMLCatalog::Resolution, or nil when no entry matches.
      def resolve_uri(name)
        return nil if name.nil?
        @catalogs.each do |catalog|
          plan = resolve_name(catalog, name, root_chain(catalog))
          return plan if plan
        end
        nil
      end

      private

      def root_chain(catalog)
        catalog.uri ? [catalog.uri] : []
      end

      def public_allowed?(entry, system_id)
        system_id.nil? or entry.prefer != "system"
      end

      def resolve_external(catalog, system_id, public_id, chain)
        if system_id
          entry = catalog.system_entries[system_id]
          return plan_for(entry, system_id, catalog, chain) if entry
        end

        normalized_public = public_id && XMLCatalog.normalize_public_id(public_id)
        if normalized_public
          entry = catalog.public_entries[normalized_public]
          if entry and public_allowed?(entry, system_id)
            return plan_for(entry, public_id, catalog, chain)
          end
        end

        if system_id
          entry = longest_prefix(catalog.rewrite_system_entries, system_id)
          return rewrite_plan_for(entry, system_id, catalog, chain) if entry

          entry = longest_suffix(catalog.system_suffix_entries, system_id)
          return plan_for(entry, system_id, catalog, chain) if entry
        end

        if normalized_public
          delegates = delegate_matches(catalog.delegate_public_entries,
                                       normalized_public)
          delegates.each do |entry|
            next unless public_allowed?(entry, system_id)
            plan = with_catalog(entry.value, chain) do |delegate, delegate_chain|
              resolve_external(delegate, system_id, public_id, delegate_chain)
            end
            return plan if plan
          end
        end

        if system_id
          delegates = delegate_matches(catalog.delegate_system_entries,
                                       system_id)
          delegates.each do |entry|
            plan = with_catalog(entry.value, chain) do |delegate, delegate_chain|
              resolve_external(delegate, system_id, public_id, delegate_chain)
            end
            return plan if plan
          end
        end

        catalog.next_catalogs.each do |next_uri|
          plan = with_catalog(next_uri, chain) do |next_catalog, next_chain|
            resolve_external(next_catalog, system_id, public_id, next_chain)
          end
          return plan if plan
        end

        nil
      end

      def resolve_name(catalog, name, chain)
        entry = catalog.uri_entries[name]
        return plan_for(entry, name, catalog, chain) if entry

        entry = longest_prefix(catalog.rewrite_uri_entries, name)
        return rewrite_plan_for(entry, name, catalog, chain) if entry

        entry = longest_suffix(catalog.uri_suffix_entries, name)
        return plan_for(entry, name, catalog, chain) if entry

        delegates = delegate_matches(catalog.delegate_uri_entries, name)
        delegates.each do |entry|
          plan = with_catalog(entry.value, chain) do |delegate, delegate_chain|
            resolve_name(delegate, name, delegate_chain)
          end
          return plan if plan
        end

        catalog.next_catalogs.each do |next_uri|
          plan = with_catalog(next_uri, chain) do |next_catalog, next_chain|
            resolve_name(next_catalog, name, next_chain)
          end
          return plan if plan
        end

        nil
      end

      def with_catalog(uri, chain)
        raise CircularDelegateError, chain + [uri] if chain.include?(uri)
        catalog = load_catalog(uri)
        return nil if catalog.nil?
        yield catalog, chain + [uri]
      end

      def load_catalog(uri)
        return @loaded_catalogs[uri] if @loaded_catalogs.key?(uri)
        catalog = nil
        if @loader
          source = @loader.call(uri)
          if source
            begin
              catalog = Parser.new.parse(source, uri)
            rescue ParseError
              # A broken delegated or next catalog is treated as empty.
              catalog = nil
            end
          end
        end
        @loaded_catalogs[uri] = catalog
      end

      def plan_for(entry, identifier, catalog, chain)
        Resolution.new(uri: entry.value,
                       match: entry.kind,
                       identifier: identifier,
                       catalog_uri: catalog.uri,
                       catalog_chain: chain)
      end

      def rewrite_plan_for(entry, identifier, catalog, chain)
        remainder = identifier[entry.key.length..-1] || ""
        Resolution.new(uri: entry.value + remainder,
                       match: entry.kind,
                       identifier: identifier,
                       catalog_uri: catalog.uri,
                       catalog_chain: chain)
      end

      def longest_prefix(entries, identifier)
        longest_prefix_matches(entries, identifier).first
      end

      def longest_prefix_matches(entries, identifier)
        matched = entries.select { |entry| identifier.start_with?(entry.key) }
        return [] if matched.empty?
        longest = matched.map { |entry| entry.key.length }.max
        matched.select { |entry| entry.key.length == longest }
      end

      # All delegate entries whose start string matches, longest match
      # first; entries with equal length keep document order.
      def delegate_matches(entries, identifier)
        matched = entries.select { |entry| identifier.start_with?(entry.key) }
        matched.sort_by.with_index { |entry, index| [-entry.key.length, index] }
      end

      def longest_suffix(entries, identifier)
        matched = entries.select { |entry| identifier.end_with?(entry.key) }
        matched.max_by { |entry| entry.key.length }
      end
    end
  end
end
