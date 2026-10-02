# Canonical XML 1.1 test vectors

Official test vectors for Canonical XML Version 1.1, pinned to the
following sources (retrieved 2026-10-02):

- W3C Recommendation "Canonical XML Version 1.1", 11 April 2013,
  <https://www.w3.org/TR/2013/REC-xml-c14n11-20130411/>:
  the example documents of section 4 ("example-4-1" to "example-4-6").
- W3C "Canonical XML 1.1 Test Cases"
  (<https://www.w3.org/TR/xml-c14n11-testcases/>):
  the xml:base and xml:id document subset cases ("xmlbase-*",
  "xmlid-*").

Adaptations required by REXML's parser (the canonical form is
unaffected):

- example-4-1: REXML strips leading and trailing whitespace of
  processing instruction data when parsing, so the xml-stylesheet
  processing instruction in the input drops the trailing spaces
  before "?>" and the expected output reflects that.
- example-4-3: REXML requires namespace declarations to appear
  before attributes that use their prefixes within the same start
  tag, so the namespace declarations of the "e5" element are moved
  in front of its other attributes.  Attribute order in the source
  does not affect the canonical form.

Known intentional deviations from libxml2 2.9.x (the specification
is followed):

- xmlbase-5: Canonical XML 1.1 joins a same-document xml:base
  reference ("#...") by concatenation, so the joined value contains
  two fragment identifiers.  libxml2 resolves it per RFC 3986 and
  keeps only the last fragment.
- xmlid-1: Canonical XML 1.1 copies the nearest ancestor xml:id
  attribute to the root of a canonicalized subtree.  libxml2 does
  not copy xml:id.
