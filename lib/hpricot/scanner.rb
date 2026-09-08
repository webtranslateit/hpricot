# frozen_string_literal: true

require 'strscan'

module Hpricot
  # Token carrying its exact source bytes.
  #
  # `raw` is the fidelity mechanism: it is the verbatim slice of the input this
  # token came from, and the tree builder stores it so serialization can emit
  # the original bytes rather than re-encoding. Never decode into `raw`.
  Token = Struct.new(:kind, :name, :attrs, :content, :raw, :closed)

  # Liberal tokenizer for HTML/XML, modelled on ext/hpricot_scan/hpricot_scan.rl.
  #
  # Rules of the port:
  #   * Never raise on malformed input. Anything unrecognised becomes text.
  #   * Every byte of the input appears in exactly one token's `raw`.
  #   * Attribute values are stored undecoded.
  class Scanner
    def initialize(source, xml: false, fixup_tags: false, xhtml_strict: false)
      @src = source
      @xml = xml
      @fixup_tags = fixup_tags
      @xhtml_strict = xhtml_strict
      # StringScanner matches against @scan_src using regexes tied to ITS
      # encoding. Documents with an invalid byte sequence for their tagged
      # encoding (common with mislabelled Latin-1/CP-1252 HTML) would make
      # ordinary regex matching raise ArgumentError, which the C scanner --
      # a byte-oriented ragel machine with no concept of encoding -- never
      # did. So all matching happens against a binary (ASCII-8BIT) view;
      # every substring that becomes visible token data (raw spans, text,
      # comment/CDATA content, tag/attribute names and values) is instead
      # re-sliced from @src by byte offset, via `span` or `String#byteslice`,
      # so it keeps @src's own encoding rather than being forced binary.
      @scan_src = source.dup.force_encoding(Encoding::ASCII_8BIT)
      @ss = StringScanner.new(@scan_src)
    end

    def tokens
      @tokens ||= begin
        out = []
        out << next_token until @ss.eos?
        out
      end
    end

    private

    def next_token
      start = @ss.pos

      if @ss.scan(/<!--/)      then comment(start)
      elsif @ss.scan(/<!\[CDATA\[/) then cdata(start)
      elsif @ss.scan(/<\?/)    then procins(start)
      elsif @ss.scan(/<!DOCTYPE/) then doctype(start) # case-sensitive: the
        # ragel grammar matches literal uppercase DOCTYPE only, so
        # '<!doctype html>' is text. Verified against the C scanner.
      elsif (m = @ss.scan(%r{</([^\s>]*)\s*>?}))
        name = span(start + 2, @ss[1].bytesize)
        # hpricot_scan.rl:317-324 downcases stag/emptytag/etag names alike in
        # HTML mode (it is the same lookup used to find the tag's content
        # model in ElementContent, whose keys are all lowercase).
        Token.new(:etag, @xml ? name : downcase(name), nil, nil, span(start), nil)
      elsif @ss.check(/<[A-Za-z_:]/)
        tag(start)
      else
        text(start)
      end
    end

    def comment(start)
      content_start = @ss.pos
      if @ss.scan_until(/-->/)
        content = span(content_start, @ss.pos - content_start - 3)
      else
        @ss.scan(/.*/m)
        content = span(content_start, @ss.pos - content_start)
      end
      Token.new(:comment, nil, nil, content, span(start), nil)
    end

    def cdata(start)
      content_start = @ss.pos
      if @ss.scan_until(/\]\]>/)
        content = span(content_start, @ss.pos - content_start - 3)
      else
        @ss.scan(/.*/m)
        content = span(content_start, @ss.pos - content_start)
      end
      Token.new(:cdata, nil, nil, content, span(start), nil)
    end

    def procins(start)
      body_start = @ss.pos
      # hpricot_common.rl:47: EndXmlProcIns = "?"? ">" -- a processing
      # instruction closes at the first bare '>' too, not only "?>". The C
      # scanner also mangles content/raw fidelity for the bare '>' case (it
      # drops the character right before '>', and fabricates a "?>" in
      # raw_string that was never in the source); this port keeps every byte
      # instead, per this project's round-tripping requirement.
      found = @ss.scan_until(/\??>/)
      term_len = found ? @ss.matched.bytesize : 0
      @ss.scan(/.*/m) unless found
      body_end = @ss.pos - term_len
      # Find target/rest boundaries against the binary buffer (safe
      # regardless of @src's declared encoding), then slice @src itself so
      # the resulting strings keep @src's encoding.
      bin_body = @scan_src.byteslice(body_start, body_end - body_start)
      target_len = bin_body[/\A\S*/].bytesize
      remainder = bin_body.byteslice(target_len..)
      lead_ws = remainder[/\A\s*/].bytesize
      trail_ws = remainder[/\s*\z/].bytesize
      rest_len = [remainder.bytesize - lead_ws - trail_ws, 0].max

      target = span(body_start, target_len)
      rest = span(body_start + target_len + lead_ws, rest_len)

      # hpricot_common.rl:39: XmlDecl requires "<?xml" to be followed
      # immediately by a well-formed version pseudo-attribute; a "<?xml ...?>"
      # that merely happens to have the target "xml" (no version, or a
      # malformed one) is just an ordinary ProcIns. Verified against the C
      # scanner: <?xml blah='blah'?> is a ProcIns, not an XMLDecl.
      bin_rest = bin_body.byteslice(target_len + lead_ws, rest_len)
      xmldecl = target == 'xml' && bin_rest.match?(/\Aversion\s*=\s*(["']).*?\1/)

      if xmldecl
        Token.new(:xmldecl, target, parse_attrs(rest), rest, span(start), nil)
      else
        Token.new(:procins, target, nil, rest, span(start), nil)
      end
    end

    def doctype(start)
      @ss.scan_until(/>/) || @ss.scan(/.*/m)
      raw = span(start)
      Token.new(:doctype, nil, parse_doctype(raw), nil, raw, nil)
    end

    def text(start)
      # Consume one '<' that did not start a recognised construct, then run to
      # the next '<'. This is what makes stray '<' render as text.
      @ss.getch if @ss.check(/</)
      @ss.scan(/[^<]*/m)
      Token.new(:text, nil, nil, nil, span(start), nil)
    end

    # Attribute names. Note that quotes are excluded: `<div "bare">` is not a
    # tag with an attribute called `"bare"`, it is text (verified against the C
    # scanner), and neither is `<div =foo>`.
    ATTR_NAME_RE = %r{[^\s=/><"']+}

    # Tag parsing is ALL-OR-NOTHING, matching the ragel grammar. If the
    # attribute list does not parse cleanly through to a closing `>`, the whole
    # construct is text rather than a malformed element. Verified against the C
    # scanner:
    #
    #   <div a="1" b>            -> Elem(div, ["a", "b"])
    #   <div a=1 b=2>            -> Elem(div, ["a", "b"])
    #   <div a==b>               -> Elem(div, ["a"])       unquoted value "=b"
    #   <div style="a="b" c">    -> Text                   stray = after a value
    #   <div a="unclosed>        -> Text                   quote never closes
    #   <div =foo>               -> Text                   name cannot start =
    #   <div "bare">             -> Text                   name cannot start "
    #   <div id="a"              -> Text                   EOF before >
    #
    # Emitting a half-parsed element instead would invent attributes out of
    # fragments of the value, which is how real documents ended up with keys
    # like `http:` and `Paulo"`.
    # hpricot_common.rl:9-10: Name = [A-Za-z_:] NameChar*, NameChar =
    # [\-A-Za-z0-9._:?]. A tag name that doesn't fit this (e.g. JavaScript's
    # "<scr" + "ipt" string-concatenation trick, which leaves a stray
    # apostrophe right after "scr") does not match StartTag at all, so the
    # whole construct falls back to text -- see the all-or-nothing note above.
    NAME_RE = /[A-Za-z_:][\-A-Za-z0-9._:?]*/

    def tag(start)
      @ss.getch                       # consume '<'
      name_start = @ss.pos
      @ss.scan(NAME_RE)
      name = span(name_start, @ss.pos - name_start)
      attrs = {}

      loop do
        @ss.scan(/\s+/)
        return text_from(start) if @ss.eos?   # no '>' before EOF
        break if @ss.check(%r{/?>})

        key_start = @ss.pos
        return text_from(start) if @ss.scan(ATTR_NAME_RE).nil?

        key = span(key_start, @ss.pos - key_start)

        val = nil
        if @ss.scan(/\s*=\s*/)
          val = if @ss.check(/["']/)
                  q_start = @ss.pos
                  quoted = @ss.scan(/"[^"]*"|'[^']*'/)
                  # An opening quote with no closing quote never terminates.
                  return text_from(start) if quoted.nil?

                  span(q_start + 1, quoted.bytesize - 2)
                else
                  # hpricot_common.rl:23's UnqAttr can only START with a
                  # non-quote character, but its body tolerates a quote
                  # anywhere -- except the %aunq action then strips exactly
                  # one trailing quote, so "class=xyz'" parses as "xyz" (a
                  # stray closing quote someone forgot to open).
                  v_start = @ss.pos
                  @ss.scan(%r{[^\s>]*})
                  unq = span(v_start, @ss.pos - v_start)
                  unq = unq[0...-1] if unq.end_with?('"', "'")
                  # A completely empty, unquoted value (name= immediately
                  # followed by whitespace or '>') never gets marked at all
                  # by hpricot_common.rl:23's UnqAttr -- only an explicit ""
                  # or '' does. Verified against the C scanner: <div a=> has
                  # {"a"=>nil}, but <div a=""> has {"a"=>""}.
                  unq.empty? ? nil : unq
                end
        end
        key = downcase(key) unless @xml
        attrs[key] = val
      end

      empty = !@ss.scan(%r{\s*/>}).nil?
      @ss.scan(/\s*>/) unless empty

      Token.new(empty ? :emptytag : :stag,
                @xml ? name : downcase(name),
                attrs, nil, span(start), empty)
    end

    # Rewinds to +start+ and re-reads the construct as text. Used when a tag
    # fails to parse; the bytes must still be accounted for exactly once.
    def text_from(start)
      @ss.pos = start
      text(start)
    end

    def span(start, length = @ss.pos - start)
      @src.byteslice(start, length)
    end

    # String#downcase raises ArgumentError on a string that is not valid in
    # its own encoding (routine for mislabelled-encoding documents). Fall
    # back to an ASCII-only-safe downcase rather than propagate that -- tag
    # and attribute names are overwhelmingly ASCII, and a scanner must never
    # raise on malformed input.
    def downcase(str)
      str.downcase
    rescue ArgumentError
      str.b.downcase.force_encoding(str.encoding)
    end

    # Used only for the pseudo-attributes of an <?xml ...?> declaration.
    # Operates like `tag`'s attribute loop: match against a binary view for
    # safety, then byteslice the result back out of `str` so values keep
    # str's own encoding.
    def parse_attrs(str)
      str = str.to_s
      attrs = {}
      s = StringScanner.new(str.b)

      until s.eos?
        s.scan(/\s+/)
        key_start = s.pos
        break if s.scan(%r{[^\s=/><]+}).nil?

        key = str.byteslice(key_start, s.pos - key_start)

        val = nil
        if s.scan(/\s*=\s*/)
          val = if (q = s.scan(/"[^"]*"|'[^']*'/))
                  str.byteslice(s.pos - q.bytesize + 1, q.bytesize - 2)
                else
                  v_start = s.pos
                  s.scan(%r{[^\s>]*})
                  str.byteslice(v_start, s.pos - v_start)
                end
        end
        key = downcase(key) unless @xml
        attrs[key] = val
      end

      attrs
    end

    def parse_doctype(raw)
      bin = raw.b
      attrs = {}
      if (m = bin.match(/\A<!DOCTYPE\s+([^\s>]+)/i))
        attrs[:target] = raw.byteslice(m.begin(1), m[1].bytesize)
      end
      if (m = bin.match(/PUBLIC\s+"([^"]*)"/i))
        attrs[:public_id] = raw.byteslice(m.begin(1), m[1].bytesize)
      end
      # SYSTEM takes one literal; PUBLIC takes a public id then an OPTIONAL
      # system id. Verified against the C scanner:
      #   <!DOCTYPE html>                         -> target only
      #   <!DOCTYPE n SYSTEM "s">                 -> target + system_id
      #   <!DOCTYPE n PUBLIC "p">                 -> target + public_id
      #   <!DOCTYPE n PUBLIC "p" "s">             -> target + public_id + system_id
      # The previous pattern required SYSTEM to be followed immediately by a
      # quote, so `SYSTEM "url"` never matched at all.
      sys = if attrs.key?(:public_id)
              bin.match(/PUBLIC\s+"[^"]*"\s+"([^"]*)"/i)
            else
              bin.match(/SYSTEM\s+"([^"]*)"/i)
            end
      attrs[:system_id] = raw.byteslice(sys.begin(1), sys[1].bytesize) if sys
      attrs
    end
  end
end
