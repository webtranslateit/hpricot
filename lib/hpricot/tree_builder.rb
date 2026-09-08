# frozen_string_literal: true

require 'hpricot/nodes'

module Hpricot
  # Turns a Scanner token stream into a Hpricot::Doc tree.
  #
  # XML mode is a straight push/pop of a stack. HTML mode additionally applies
  # implicit closing driven by ElementContent (see #close_implied), matching
  # ext/hpricot_scan/hpricot_scan.rl:316-400.
  class TreeBuilder
    def initialize(tokens, xml: false, fixup_tags: false, xhtml_strict: false)
      @tokens = tokens
      @xml = xml
      @fixup_tags = fixup_tags
      @xhtml_strict = xhtml_strict
    end

    def document
      @document ||= build
    end

    private

    def build
      doc = Doc.allocate
      doc.children = []
      @stack = [doc]

      @tokens.each { |tok| consume(tok) }

      doc
    end

    def focus = @stack.last

    def add(node)
      node.parent = focus
      (focus.children ||= []) << node
      node
    end

    def consume(tok)
      case tok.kind
      when :text      then add(text_node(tok))
      when :comment   then add(simple(Comment, tok.content))
      when :cdata     then add(simple(CData, tok.content))
      when :procins   then add(procins(tok))
      when :xmldecl   then add(xmldecl(tok))
      when :doctype   then add(doctype(tok))
      when :stag      then open_element(tok)
      when :emptytag  then add(element(tok))
      when :etag      then close_element(tok)
      end
    end

    def text_node(tok)
      t = Text.allocate
      t.content = tok.raw
      t
    end

    def simple(klass, content)
      n = klass.allocate
      n.content = content
      n
    end

    def procins(tok)
      p = ProcIns.allocate
      p.target = tok.name
      p.content = tok.content
      p
    end

    def xmldecl(tok)
      x = XMLDecl.allocate
      x.raw_attributes = {
        version: tok.attrs['version'],
        encoding: tok.attrs['encoding'],
        standalone: tok.attrs['standalone']
      }
      x.name = tok.raw
      x
    end

    def doctype(tok)
      d = DocType.allocate
      d.raw_attributes = tok.attrs
      d.name = tok.raw
      d
    end

    def element(tok)
      e = Elem.allocate
      e.name = tok.name
      e.raw_attributes = tok.attrs
      e.raw_string = tok.raw
      e.tagno = tok.name.hash
      e.allowed = ElementContent[tok.name] unless @xml
      e
    end

    def open_element(tok)
      close_implied(tok.name) unless @xml
      e = add(element(tok))
      e.children = []
      @stack.push(e)
    end

    def close_element(tok)
      idx = @stack.rindex { |n| n.is_a?(Elem) && n.name == tok.name }

      if idx.nil?
        # No matching open tag: hpricot keeps the bytes as a BogusETag rather
        # than discarding them, which is required for byte-identical output.
        b = BogusETag.allocate
        b.name = tok.name
        # NOTE: the C extension defines BogusETag#raw_string as a GETTER only
        # (rb_define_method(cBogusETag, "raw_string", hpricot_ele_get_attr, 0));
        # there is no raw_string= setter. Assign through the slot itself.
        b.raw_attributes = tok.raw
        add(b)
        return
      end

      @stack[idx].etag = tok.raw
      @stack.pop(@stack.length - idx)
    end

    # HTML implicit closing: <li> closes an open <li>, <td> closes <td>, and so
    # on. ElementContent[open_tag] is a Hash keyed by tag_name.hash whose value
    # says whether the new tag may appear inside the open one.
    def close_implied(new_name)
      key = new_name.hash
      while (open = focus) && open.is_a?(Elem)
        allowed = open.allowed
        break if allowed.nil?
        break if allowed[key]

        @stack.pop
      end
    end
  end
end
