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
    def initialize(source, xml: false, fixup_tags: false, xhtml_strict: false, html_void: false)
      @xml = xml
      @fixup_tags = fixup_tags
      @xhtml_strict = xhtml_strict
      # Consumed by TreeBuilder; accepted here so Hpricot.scan can pass one
      # option hash to both.
      @html_void = html_void

      # Lowest position from which no '>' (respectively ']') remains in the
      # document. Both start unknown. See gt_ahead?.
      @no_gt_from = nil
      @no_rbracket_from = nil

      # Which encoding the token strings carry.
      #
      # A BINARY source carries no information about what its bytes mean --
      # it is what File.binread and Zip::File#read hand back -- so tag the
      # output Encoding.default_external, which is what the C scanner did for
      # every input. Callers rely on this: language_file_handler reads .docx
      # parts out of a zip (binary) and passes the result straight to
      # HTMLEntities#decode, which raises on an ASCII-8BIT string.
      #
      # A source that declares a real encoding is believed, which is where
      # this departs from the C scanner. That tagged every node
      # default_external regardless, so parsing an ISO-8859-1 document
      # produced UTF-8-labelled strings that failed valid_encoding?.
      @out_encoding =
        if source.encoding == Encoding::ASCII_8BIT
          Encoding.default_external
        else
          source.encoding
        end

      # What the regexes run against.
      #
      # Matching has to tolerate bytes that are invalid for the source's
      # declared encoding -- mislabelled Latin-1/CP-1252 HTML is common, and
      # the C scanner, a byte-oriented ragel machine with no concept of
      # encoding, never cared. An ordinary regex match on such a string raises
      # ArgumentError, so those get a binary view.
      #
      # A source that is already valid in an ASCII-compatible encoding needs no
      # copy: StringScanner#pos and #skip are byte-oriented whatever the
      # encoding, so the offset arithmetic here is unaffected, and `\s`, `\S`
      # and the character classes used below are all ASCII-only in Ruby. That
      # matters because the copy is the size of the document -- 1.5MB of
      # copying per parse, on top of a second full copy this used to make to
      # re-tag the source for output.
      @scan_src =
        if source.encoding.ascii_compatible? && source.valid_encoding?
          source
        else
          source.b
        end

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

    LT       = 0x3C # '<'
    BANG     = 0x21 # '!'
    QUESTION = 0x3F # '?'
    SLASH    = 0x2F # '/'

    def next_token
      start = @ss.pos

      # A token that does not begin with '<' can only be text. getbyte finds
      # that out without allocating, and most tokens in a real document are
      # text.
      return text(start) unless @scan_src.getbyte(start) == LT

      # Dispatch on the SECOND byte rather than trying each construct in turn.
      # A start tag is the commonest '<' token, and it used to pay four failed
      # regex attempts plus a check before reaching `tag`. One byte removes all
      # of that: worth ~15% on a real document, and it is pure interpreter work
      # removed -- allocation counts are unchanged.
      case @scan_src.getbyte(start + 1)
      when BANG                      # comment, CDATA section or doctype
        if @ss.skip(/<!--/)          then comment(start)
        elsif @ss.skip(/<!\[CDATA\[/) then cdata(start)
        # Case-sensitive: hpricot_common.rl:45 matches literal uppercase
        # DOCTYPE only, so '<!doctype html>' is text.
        elsif @ss.skip(/<!DOCTYPE/)  then doctype(start)
        else text(start)
        end
      when QUESTION                  # processing instruction or XML declaration
        @ss.skip(/<\?/) ? procins(start) : text(start)
      when SLASH                     # end tag
        etag(start)
      else
        @ss.check(/<[A-Za-z_:]/) ? tag(start) : text(start)
      end
    end

    # hpricot_common.rl:32: EndTag = "</" NameCap space* ">". Both a valid Name
    # and the closing '>' are required; "</>", "</ >" and an unterminated "</x"
    # are text, as they are to the C scanner. Accepting them produced a
    # BogusETag, whose #output emits nothing, so to_html silently dropped those
    # bytes.
    def etag(start)
      return text(start) unless @ss.scan(%r{</(#{NAME_RE.source})\s*>}o)

      # hpricot_scan.rl:317-324 downcases stag/emptytag/etag names alike in HTML
      # mode: it is the same lookup used to find the tag's content model in
      # ElementContent, whose keys are all lowercase.
      name = span(start + 2, @ss[1].bytesize)
      Token.new(:etag, @xml ? name : downcase(name), nil, nil, span(start), nil)
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
      # hpricot_common.rl:46-47:
      #   StartXmlProcIns = "<?" Name space+
      #   EndXmlProcIns   = "?"? ">"
      # A terminator is required. An unterminated "<?x" or "<?xml version='1.0'"
      # is text, as it is to the C scanner. Accepting it produced a ProcIns or
      # XMLDecl whose to_html fabricated a "?>" that was never in the source.
      # hpricot_common.rl:46 requires whitespace after the Name:
      #   StartXmlProcIns = "<?" Name space+
      # so "<?x?>" and "<?x>" are text, not processing instructions. Verified
      # against the C scanner.
      # check, not a byteslice of the remaining document: that copied the whole
      # tail on every processing instruction.
      return text_from(start) unless @ss.check(/#{NAME_RE.source}\s/o)
      return text_from(start) unless gt_ahead?

      found = @ss.scan_until(/\??>/)
      return text_from(start) unless found

      term_len = @ss.matched.bytesize
      body_end = @ss.pos - term_len
      # Find the target/rest boundary against the scanning buffer, then slice
      # by byte offset so the result carries the output encoding. Note the
      # buffer is only a separate BINARY copy when the source was invalid for
      # its declared encoding; in the common path it IS the source, and these
      # slice boundaries are character boundaries either way.
      bin_body = @scan_src.byteslice(body_start, body_end - body_start)
      target_len = bin_body[/\A\S*/].bytesize
      remainder = bin_body.byteslice(target_len..)
      # Only the leading separator is consumed; trailing whitespace belongs to
      # the content. The C scanner stores "echo 1; " for "<?php echo 1; ?>",
      # and stripping it changed what to_html emitted.
      lead_ws = remainder[/\A\s*/].bytesize
      rest_len = [remainder.bytesize - lead_ws, 0].max

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

    # hpricot_common.rl:45:
    #   DocType = "<!DOCTYPE" space+ NameCap (space+ ExternalID)? space*
    #             ("[" [^\]]* "]" space*)? ">"
    #
    # Whitespace, a Name and a closing '>' are all required, and an internal
    # subset in brackets is skipped WHOLE -- it contains '>' characters of its
    # own, so stopping at the first one truncated the doctype and leaked the
    # trailing "]>" into the document as a text node. Internal subsets appear
    # in real XLIFF and TMX files.
    #
    # Anything not matching is text, as it is to the C scanner. Accepting a
    # bare "<!DOCTYPE" produced a DocType with no target, and DocType#output
    # then fabricated "<!DOCTYPE  SYSTEM>" out of nothing.
    def doctype(start)
      return text_from(start) unless @ss.skip(/\s+#{NAME_RE.source}/o)

      # No terminator anywhere ahead: bail now rather than scanning to EOF and
      # rewinding, which is what made this quadratic.
      return text_from(start) unless gt_ahead?

      @ss.skip(/[^>\[]*/)                                # external identifiers
      @ss.skip(/\[[^\]]*\]\s*/) if rbracket_ahead?      # internal subset
      return text_from(start) unless gt_ahead? && @ss.skip(/[^>]*>/)

      raw = span(start)
      Token.new(:doctype, nil, parse_doctype(raw), nil, raw, nil)
    end

    def text(start)
      # Consume one '<' that did not start a recognised construct, then run to
      # the next '<'. This is what makes a stray '<' render as text. One skip
      # does the job of check + getch + scan, and allocates nothing.
      @ss.skip(/<?[^<]*/m)
      Token.new(:text, nil, nil, nil, span(start), nil)
    end


    # One attribute in a single scan: leading whitespace, the name, and
    # optionally '=' with a value in any of its three forms.
    #
    # This loop used to make six StringScanner calls per attribute plus a
    # byteslice each for the name and the value. One check and one scan
    # measured ~47% faster on the scanning loop in isolation, and the capture
    # groups are the strings themselves, so the byteslices go away too.
    #
    # The unquoted alternative excludes a LEADING quote deliberately. Without
    # that, '<div a="unclosed>' would match '"unclosed>' as an unquoted value
    # and parse as an element; instead the next iteration meets the stray quote,
    # fails to match a name, and the whole tag falls back to text the way the C
    # scanner does. '<' is excluded throughout per hpricot_common.rl:23 --
    # including it was quadratic.
    ATTR_RE = %r{\s*([^\s=/><"']+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s<>"'][^\s<>]*)?))?}

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
      @ss.pos += 1                    # consume '<' without allocating
      name_start = @ss.pos
      # skip, not scan: scan allocates the matched String only for it to be
      # discarded, because the visible value is re-sliced by `span`
      # to keep the source encoding. Same below, six times per tag.
      @ss.skip(NAME_RE)
      name = span(name_start, @ss.pos - name_start)
      attrs = {}

      loop do
        break if @ss.check(%r{\s*/?>})
        return text_from(start) if @ss.scan(ATTR_RE).nil?

        key = retag(@ss[1])
        key = downcase(key) unless @xml

        # The three value alternatives are mutually exclusive, so at most one
        # group is set: 2 is double-quoted, 3 single-quoted, 4 unquoted.
        if (val = @ss[2] || @ss[3])
          attrs[key] = retag(val)
        elsif (val = @ss[4])
          # hpricot_common.rl:23's %aunq action strips exactly one trailing
          # quote, so "class=xyz'" parses as "xyz" -- a stray closing quote
          # someone forgot to open.
          val = val[0...-1] if val.end_with?('"', "'")
          # A completely empty unquoted value (name= followed immediately by
          # whitespace or '>') is never marked at all; only an explicit "" or
          # '' is. Verified against the C scanner: <div a=> gives {"a"=>nil},
          # <div a=""> gives {"a"=>""}.
          attrs[key] = val.empty? ? nil : retag(val)
        else
          attrs[key] = nil
        end
      end

      empty = !@ss.skip(%r{\s*/>}).nil?
      @ss.skip(/\s*>/) unless empty

      Token.new(empty ? :emptytag : :stag,
                @xml ? name : downcase(name),
                attrs, nil, span(start), empty)
    end

    # Is there a '>' at or after the scan position?
    #
    # doctype and procins scan forward for a terminator that may not exist. When
    # it does not, the scan runs to EOF, text_from then rewinds to the
    # construct's start, and text consumes only as far as the NEXT '<' -- so the
    # whole tail is rescanned once per construct. That is quadratic: 1MB of
    # '<!DOCTYPE h SYSTEM "' took 264 seconds.
    #
    # byteindex is a memchr, and the memo makes every call after the first "no"
    # O(1). The memo records a POSITION rather than a boolean because
    # "no '>' from here" is only sound for positions at or after that point;
    # a bare flag is wrong, since the internal-subset skip can legitimately
    # consume a '>' and leave later ones reachable. `<!DOCTYPE h [<?x >]` is the
    # case that catches it -- the PI must survive.
    def gt_ahead?
      pos = @ss.pos
      return false if @no_gt_from && pos >= @no_gt_from
      return true if @scan_src.byteindex('>', pos)

      @no_gt_from = pos
      false
    end

    def rbracket_ahead?
      pos = @ss.pos
      return false if @no_rbracket_from && pos >= @no_rbracket_from
      return true if @scan_src.byteindex(']', pos)

      @no_rbracket_from = pos
      false
    end

    # Rewinds to +start+ and re-reads the construct as text. Used when a tag
    # fails to parse; the bytes must still be accounted for exactly once.
    def text_from(start)
      @ss.pos = start
      text(start)
    end

    # Re-tags a string the regex engine produced from the scanning buffer.
    # force_encoding does not copy, so this is free, and it is a no-op unless
    # the source was BINARY and the output encoding is default_external.
    def retag(str)
      return str if str.nil? || str.encoding == @out_encoding

      str.force_encoding(@out_encoding)
    end

    # Slices from the scanning buffer and re-tags the result, rather than
    # slicing a separately re-encoded copy of the whole document.
    # String#force_encoding does not copy, so this costs one allocation for the
    # slice and nothing for the encoding.
    def span(start, length = @ss.pos - start)
      out = @scan_src.byteslice(start, length)
      out.force_encoding(@out_encoding) if out && out.encoding != @out_encoding
      out
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
      if (m = bin.match(/PUBLIC\s+(?:"([^"]*)"|'([^']*)')/i))
        g = m[1] ? 1 : 2
        attrs[:public_id] = raw.byteslice(m.begin(g), m[g].bytesize)
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
              bin.match(/PUBLIC\s+(?:"[^"]*"|'[^']*')\s+(?:"([^"]*)"|'([^']*)')/i)
            else
              bin.match(/SYSTEM\s+(?:"([^"]*)"|'([^']*)')/i)
            end
      if sys
        g = sys[1] ? 1 : 2
        attrs[:system_id] = raw.byteslice(sys.begin(g), sys[g].bytesize)
      end
      attrs
    end
  end
end
