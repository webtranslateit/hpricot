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

    # HTML implicit closing.
    #
    # NOTE: this does not match the plan's Task 7 sketch, which only ever
    # looks at the *current* focus on each loop iteration (pop while its
    # content model denies/omits the new tag, stop at the first true/:allow).
    # That version gives the wrong answer whenever a :deny further up the
    # ancestor chain needs to cancel a :true/:allow found closer to the
    # focus -- verified against the real C scanner
    # (ext/hpricot_scan/hpricot_scan.rl:345-386), e.g.:
    #
    #   <button><span><a>text<a>text2</a></a></span></button>
    #
    # <span>'s content model allows <a>, but the outer <button> excludes it
    # (ElementExclusions). The C scanner nests the second <a> straight
    # inside the first with NO implicit close at all, because <button>'s
    # :deny cancels the :true that <span> would otherwise have granted. A
    # loop that only ever consults the current focus can't see that: it
    # would stop as soon as it reached <span> and incorrectly close the
    # first <a>.
    #
    # So instead this walks the *entire* ancestor chain from the current
    # focus up to the document root before deciding where the new element
    # attaches. Each ancestor `e` is consulted via its own content model
    # (`e.allowed`, i.e. ElementContent[e.name], stashed on the element when
    # it was opened):
    #
    #   * `true`  — new tag may nest here; remember `e` as a candidate parent,
    #     but only if no candidate has been found yet (an ancestor further
    #     from the focus should not override one found closer, unless
    #     overruled by :allow/:deny below).
    #   * `:allow` (from ElementInclusions, e.g. <body> allows stray <ins>) —
    #     unconditionally reinstate the *original* focus as the candidate,
    #     even if a `:deny` found closer to the focus had cleared it.
    #   * `:deny` (from ElementExclusions, e.g. <a> excludes nested <a>) —
    #     unconditionally clear the candidate, forcing the search to continue
    #     further up (or fall back to the original focus if nothing else
    #     matches).
    #   * missing key (the ancestor's content model exists but says nothing
    #     about this tag) — no opinion; leave the candidate as-is and keep
    #     walking.
    #   * no content model at all (e.g. an unrecognised ancestor tag) — same
    #     as "no opinion" above, except that if nothing has matched yet, this
    #     ancestor becomes a fallback candidate ("unknown elements can
    #     contain anything"); an outer ancestor can still overrule it.
    #
    # If the new tag itself has no ElementContent entry at all (an
    # unrecognised/custom tag), none of this runs: unknown tags never trigger
    # implicit closes and simply nest at the current focus.
    #
    # Once the walk finds a target ancestor, every element between the
    # current focus and that ancestor is dropped off the stack *without*
    # being given an `etag` — matching hpricot's existing behaviour where an
    # implicitly-closed element is serialized from its raw_string/children
    # alone, with no synthetic closing tag text.
    def close_implied(new_name)
      return unless ElementContent.key?(new_name)

      key = new_name.hash
      original_focus = focus
      match = nil
      e = original_focus

      while e.is_a?(Elem)
        allowed = e.allowed

        if allowed.is_a?(Hash)
          case allowed[key]
          when true   then match ||= e
          when :allow then match = original_focus
          when :deny  then match = nil
          end
        else
          # No content model on this ancestor: treat it like an
          # unrecognised tag, which can contain anything.
          match ||= e
        end

        e = e.parent
      end

      match ||= original_focus
      idx = @stack.index(match)
      @stack.pop(@stack.length - 1 - idx) if idx
    end
  end
end
