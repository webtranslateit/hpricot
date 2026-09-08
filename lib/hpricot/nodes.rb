# frozen_string_literal: true

# Plain-Ruby replacements for the Struct-like classes the C extension built.
#
# Slot layout is preserved from ext/hpricot_scan/hpricot_scan.rl:853-861 so that
# traverse.rb, elements.rb and builder.rb work unchanged:
#
#   basic (2): name, parent
#   attr  (3): name, parent, raw_attributes
#   elem  (8): name, parent, raw_attributes, etag, raw_string, allowed,
#              tagno, children
module Hpricot
  # Shared by Text, Comment, CData.
  class BasicNode
    attr_accessor :name, :parent
  end

  # Shared by DocType, ProcIns, XMLDecl, BogusETag.
  class AttrNode
    attr_accessor :name, :parent, :raw_attributes
  end

  # Shared by Doc and Elem.
  class ElemNode
    attr_accessor :name, :parent, :raw_attributes, :etag, :raw_string,
                  :allowed, :tagno, :children
  end

  class Text < BasicNode
    alias content name
    alias content= name=
    alias raw_string name

    def clear_raw
      self.name = nil
    end
  end

  # Comment and CData carry a raw_string in addition to their content, which
  # the C extension did not. Their #content excludes the delimiters, so
  # preserve-mode output had to reconstruct "<!--" + content + "-->"; for an
  # UNTERMINATED comment there is no "-->" in the source and that reconstruction
  # corrupts the document. The C scanner got this wrong in the other direction,
  # dropping the opening "<!--" and losing four bytes:
  #
  #   input:  <p>a</p><!-- never closed
  #   C:      <p>a</p> never closed        (4 bytes lost)
  #
  # Byte-identical round-tripping is this library's reason to exist, so the raw
  # span is kept and emitted verbatim. For well-formed comments the two are the
  # same string, so nothing else changes.
  class Comment < BasicNode
    attr_accessor :raw_string

    alias content name
    alias content= name=

    def clear_raw
      self.raw_string = nil
    end
  end

  class CData < BasicNode
    attr_accessor :raw_string

    alias content name
    alias content= name=

    def clear_raw
      self.raw_string = nil
    end
  end

  class DocType < AttrNode
    alias raw_string name

    def clear_raw
      self.name = nil
    end

    def target       = (raw_attributes || {})[:target]
    def public_id    = (raw_attributes || {})[:public_id]
    def system_id    = (raw_attributes || {})[:system_id]

    def target=(v)
      (self.raw_attributes ||= {})[:target] = v
    end

    def public_id=(v)
      (self.raw_attributes ||= {})[:public_id] = v
    end

    def system_id=(v)
      (self.raw_attributes ||= {})[:system_id] = v
    end
  end

  class XMLDecl < AttrNode
    alias raw_string name

    def clear_raw
      self.name = nil
    end

    def version        = (raw_attributes || {})[:version]
    def encoding       = (raw_attributes || {})[:encoding]
    def standalone     = (raw_attributes || {})[:standalone]

    def version=(v)
      (self.raw_attributes ||= {})[:version] = v
    end

    def encoding=(v)
      (self.raw_attributes ||= {})[:encoding] = v
    end

    def standalone=(v)
      (self.raw_attributes ||= {})[:standalone] = v
    end
  end

  class ProcIns < AttrNode
    alias target name
    alias target= name=
    alias content raw_attributes
    alias content= raw_attributes=
  end

  class BogusETag < AttrNode
    alias raw_string raw_attributes

    def clear_raw
      self.raw_attributes = nil
    end
  end

  class Elem < ElemNode
    def clear_raw
      self.raw_string = nil
    end
  end

  class Doc < ElemNode
  end
end
