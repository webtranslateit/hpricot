# frozen_string_literal: true

require 'hpricot/nodes'

module Hpricot
  # Turns a Scanner token stream into a Hpricot::Doc tree.
  #
  # XML mode is a straight push/pop of a stack. HTML mode additionally applies
  # implicit closing driven by ElementContent (see #close_implied), matching
  # ext/hpricot_scan/hpricot_scan.rl:316-400.
  class TreeBuilder
    def initialize(tokens, xml: false, fixup_tags: false, xhtml_strict: false, html_void: false,
                   void_elements: nil)
      @tokens = tokens
      @xml = xml
      # Which tag names are void in XML mode, or nil for none (ordinary XML).
      # :void_elements names the set outright; :html_void is shorthand for
      # HTML's own list. An explicit set wins, so a caller can narrow the list
      # without restating it as a negation.
      @void_tags = void_elements || (html_void ? VOID_TAGS : nil)
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
      # How many Elem nodes are open for each tag name. close_element consults
      # this before scanning the stack: an end tag matching nothing at all is
      # the common case in malformed input, and scanning the whole stack for
      # each one made that quadratic.
      @open_counts = Hash.new(0)
      # Per content-model key, the stack indices of currently-open elements
      # carrying an :allow or :deny for it, outermost first. Naturally sorted:
      # elements are pushed with increasing index and popped from the top.
      # See OVERRIDING_KEYS and close_implied.
      @override_indices = Hash.new { |h, k| h[k] = [] }
      # Tracks the most recently added node under the CURRENT focus, so
      # adjacent text tokens can be merged into one Text node instead of
      # becoming siblings. Reset to nil whenever focus changes (an element is
      # opened or a matching end tag closes one) -- see
      # ext/hpricot_scan/hpricot_scan.rl:297,398,442,523. Any other node
      # creation (text, comment, cdata, procins, doctype, xmldecl, an empty or
      # bogus element) just becomes the new @last.
      @last = nil

      @tokens.each { |tok| consume(tok) }

      doc
    end

    def focus = @stack.last

    def add(node)
      node.parent = focus
      (focus.children ||= []) << node
      @last = node
      node
    end

    # Tokens that keep their own node type even while the focus is a raw-text
    # element (<script>, <style>, ...): everything else collapses to text.
    # Mirrors the gate in hpricot_scan.rl:322-333.
    CDATA_PASSTHROUGH = %i[text comment cdata procins].freeze

    def consume(tok)
      if !@xml && focus.is_a?(Elem) && focus.allowed == :CDATA && cdata_reinterprets?(tok)
        return add_text(tok.raw)
      end

      case tok.kind
      when :text      then add_text(tok.raw)
      when :comment   then add(simple(Comment, tok.content, tok.raw))
      when :cdata     then add(simple(CData, tok.content, tok.raw))
      when :procins   then add(procins(tok))
      when :xmldecl   then add(xmldecl(tok))
      when :doctype   then add(doctype(tok))
      when :stag      then handle_stag(tok)
      when :emptytag  then handle_emptytag(tok)
      when :etag      then close_element(tok)
      end
    end

    def cdata_reinterprets?(tok)
      return false if CDATA_PASSTHROUGH.include?(tok.kind)
      return false if tok.kind == :etag && tok.name == focus.name

      true
    end

    # Appends to the previous sibling if it is itself a Text node (matching
    # ext/hpricot_scan/hpricot_scan.rl:470-476), otherwise starts a new one.
    # This is what makes a stray '<' in running text ("a < b") one Text node
    # instead of two.
    def add_text(raw)
      if @last.is_a?(Text)
        # Mutate in place. Rebuilding with + copied the whole accumulated
        # text on every adjacent token, making "a < b" in ordinary prose
        # quadratic: 1MB took 3.6s, and 1M bare '<' took 22s.
        #
        # Appending is safe, but NOT because the slice is unshared -- Ruby
        # shares tail substrings, and ObjectSpace.memsize_of on a 1000-byte
        # byteslice reports 40. It is safe because that sharing is
        # copy-on-write: the first append gives the slice its own buffer and
        # leaves the source untouched.
        @last.content << raw
      else
        t = Text.allocate
        t.content = raw
        add(t)
      end
    end

    def simple(klass, content, raw = nil)
      n = klass.allocate
      n.content = content
      n.raw_string = raw if raw && n.respond_to?(:raw_string=)
      n
    end

    def procins(tok)
      p = ProcIns.allocate
      p.target = tok.name
      p.content = tok.content
      p.raw_string = tok.raw
      p
    end

    def xmldecl(tok)
      x = XMLDecl.allocate
      # Only keys actually present in the declaration are stored. The C scanner
      # sets each via its ATTR() macro as the grammar matches it, so an absent
      # encoding leaves no :encoding key at all rather than one set to nil.
      attrs = {}
      %w[version encoding standalone].each do |k|
        attrs[k.to_sym] = tok.attrs[k] if tok.attrs.key?(k)
      end
      x.raw_attributes = attrs
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
      # nil, not {}, when the tag carried no attributes: the C scanner only
      # allocates the hash when its ATTR() macro first fires, so an
      # attribute-less element has no raw_attributes at all. Code downstream
      # distinguishes the two (Elem#attributes_as_html, and the inspect output).
      e.raw_attributes = tok.attrs.empty? ? nil : tok.attrs
      e.raw_string = tok.raw
      e.tagno = tok.name.hash

      if @xml
        # XML has no void elements, so nothing is marked :EMPTY and <br> is an
        # ordinary container. html_void opts into HTML's list while leaving the
        # rest of XML parsing alone -- for callers who are parsing HTML through
        # Hpricot::XML and want <br> to behave like <br>. See VOID_TAGS.
        # :VOID rather than :EMPTY, so the serializer can tell the two apart.
        # Both mean "takes no children"; only :EMPTY also means "write it the
        # XHTML way, with a self-closing slash". HTML mode keeps :EMPTY and so
        # keeps emitting '<br />'; html_void writes '<br>' as the source did,
        # which matters when the element sits inside translatable text.
        #
        # void_elements names the set instead of taking HTML's whole list,
        # because void-ness belongs to the document type rather than to the tag
        # name. An XML vocabulary is free to reuse a name HTML happens to treat
        # as void and mean a container by it -- TYPO3's locallang XML has a
        # <meta> holding <type> and <description> -- and applying HTML's list
        # there drops the children and the end tag. Such a caller asks for the
        # one or two names it actually needs, typically %w[br].
        e.allowed = :VOID if @void_tags&.key?(tok.name)
      else
        e.allowed = ElementContent[tok.name]
      end

      e
    end

    # In HTML mode, a start tag whose content model is :EMPTY (e.g. <br>,
    # <link>) never gets focused even without a trailing '/', and conversely
    # a "<foo/>" spelling of a non-:EMPTY tag is just an ordinary start tag
    # (the '/' is not honoured). Mirrors hpricot_scan.rl:335-340.
    def handle_stag(tok)
      close_implied(tok.name) unless @xml
      e = add(element(tok))
      # Not `@xml || ...`: under html_void a void element is marked in XML mode
      # too, and must not be focused. Plain XML mode is unaffected, since
      # nothing is marked there.
      unless Elem::VOID_MODELS.include?(e.allowed)
        e.children = []
        push(e)
      end
    end

    def handle_emptytag(tok)
      close_implied(tok.name) unless @xml
      e = add(element(tok))
      return if @xml

      # hpricot_scan.rl:335-340 only reclassifies "<foo/>" as an ordinary
      # start tag (pushing it as a container) when foo has a KNOWN,
      # non-:EMPTY content model. An unrecognised tag (e.allowed is nil --
      # no ElementContent entry at all, e.g. a namespaced RSS/Atom element
      # like <dc:creator/>) keeps its self-closed spelling and is never
      # focused, matching the "/" the author actually wrote.
      if !e.allowed.nil? && e.allowed != :EMPTY
        e.children = []
        push(e)
      end
    end

    # Every stack mutation goes through push/pop_to so @open_counts cannot
    # drift out of step with @stack.
    # HTML's void elements, taken from ElementContent so this cannot drift from
    # what HTML mode already does: br, img, hr, input, meta, link and the rest.
    VOID_TAGS = ElementContent.each_with_object({}) do |(name, model), h|
      h[name] = true if model == :EMPTY
    end.freeze

    # For each tag name, which content-model KEYS carry an :allow or :deny --
    # the only entries that can override a match found at an inner ancestor.
    # Only 10 of ElementContent's 89 tags have any, and each has a handful, so
    # maintaining open counts per key is cheap and lets close_implied stop at
    # the first match in every case except the one that genuinely needs the
    # full walk.
    OVERRIDING_KEYS = ElementContent.each_with_object({}) do |(name, model), h|
      next unless model.is_a?(Hash)

      keys = model.each_with_object([]) { |(k, v), a| a << k if v == :allow || v == :deny }
      h[name] = keys unless keys.empty?
    end.freeze

    def push(elem)
      @stack.push(elem)
      @open_counts[elem.name] += 1
      idx = @stack.length - 1
      OVERRIDING_KEYS[elem.name]&.each { |k| @override_indices[k] << idx }
      @last = nil
    end

    # Pops until the stack is +depth+ deep.
    def pop_to(depth)
      while @stack.length > depth
        popped = @stack.pop
        next unless popped.is_a?(Elem)

        @open_counts[popped.name] -= 1
        OVERRIDING_KEYS[popped.name]&.each { |k| @override_indices[k].pop }
      end
      @last = nil
    end

    def close_element(tok)
      # O(1) for an end tag with no matching open element, which is what
      # malformed input is full of. Without this the rindex below scanned the
      # entire open-element stack for every one of them: 352KB of
      # "<x:a>"*n + "</zzz>"*n took 58 seconds.
      idx = @open_counts[tok.name].zero? ? nil : @stack.rindex { |n| n.is_a?(Elem) && n.name == tok.name }

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
      pop_to(idx)
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
      top = @stack.length - 1

      # The walk goes focus -> parent -> ... -> root, and @stack is exactly
      # that chain with root at index 0, so the stack index is just the loop
      # counter. Tracking it here removes a second full scan
      # (@stack.index(match)) that used to run after the walk.
      #
      # An :allow or :deny is applied AFTER everything inner and overwrites it
      # outright, so when any open element carries one for this key, the
      # OUTERMOST such element decides the outcome and every ancestor between
      # it and the focus is irrelevant. Jumping straight to it keeps this O(1)
      # amortised instead of O(depth) per start tag. Without it, 78KB of
      # "<button>" + "<a>x"*n took 19 seconds.
      outermost = @override_indices[key].first

      if outermost
        match_idx = @stack[outermost].allowed[key] == :allow ? top : nil
        i = outermost - 1
      else
        match_idx = nil
        i = top
      end

      while i.positive? && (e = @stack[i]).is_a?(Elem)
        allowed = e.allowed

        if allowed.is_a?(Hash)
          case allowed[key]
          when true   then match_idx ||= i
          when :allow then match_idx = top
          when :deny  then match_idx = nil
          end
        else
          # No content model on this ancestor: treat it like an
          # unrecognised tag, which can contain anything.
          match_idx ||= i
        end

        # Everything from here outwards carries no override for this key
        # (the outermost one, if any, was applied above), so once a match is
        # found nothing further out can change it.
        break if match_idx

        i -= 1
      end

      match_idx ||= top
      pop_to(match_idx + 1)
    end
  end
end
