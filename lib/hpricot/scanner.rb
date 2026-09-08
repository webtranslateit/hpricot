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
      @ss = StringScanner.new(source)
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
        name = @ss[1]
        # hpricot_scan.rl:317-324 downcases stag/emptytag/etag names alike in
        # HTML mode (it is the same lookup used to find the tag's content
        # model in ElementContent, whose keys are all lowercase).
        Token.new(:etag, @xml ? name : name.downcase, nil, nil, m, nil)
      elsif @ss.check(/<[A-Za-z_:]/)
        tag(start)
      else
        text(start)
      end
    end

    # Scans to `terminator`, or to EOF if it never appears (liberality).
    def upto(terminator)
      body = @ss.scan_until(terminator)
      return [@ss.scan(/.*/m), false] if body.nil?

      [body[0...-terminator.source.length] || body, true]
    end

    def comment(start)
      inner = @ss.scan_until(/-->/)
      if inner.nil?
        inner = @ss.scan(/.*/m).to_s
        content = inner
      else
        content = inner[0...-3]
      end
      Token.new(:comment, nil, nil, content, span(start), nil)
    end

    def cdata(start)
      inner = @ss.scan_until(/\]\]>/)
      if inner.nil?
        inner = @ss.scan(/.*/m).to_s
        content = inner
      else
        content = inner[0...-3]
      end
      Token.new(:cdata, nil, nil, content, span(start), nil)
    end

    def procins(start)
      inner = @ss.scan_until(/\?>/)
      inner = @ss.scan(/.*/m).to_s if inner.nil?
      body = inner.sub(/\?>\z/, '')
      target = body[/\A[^\s]+/].to_s
      rest = body[target.length..].to_s.strip

      if target == 'xml'
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
    def tag(start)
      @ss.getch                       # consume '<'
      name = @ss.scan(%r{[^\s/>]+}).to_s
      attrs = {}

      loop do
        @ss.scan(/\s+/)
        return text_from(start) if @ss.eos?   # no '>' before EOF
        break if @ss.check(%r{/?>})

        key = @ss.scan(ATTR_NAME_RE)
        return text_from(start) if key.nil?

        val = nil
        if @ss.scan(/\s*=\s*/)
          val = if @ss.check(/["']/)
                  quoted = @ss.scan(/"[^"]*"|'[^']*'/)
                  # An opening quote with no closing quote never terminates.
                  return text_from(start) if quoted.nil?

                  quoted[1...-1]
                else
                  @ss.scan(%r{[^\s>]*})
                end
        end
        key = key.downcase unless @xml
        attrs[key] = val
      end

      empty = !@ss.scan(%r{\s*/>}).nil?
      @ss.scan(/\s*>/) unless empty

      Token.new(empty ? :emptytag : :stag,
                @xml ? name : name.downcase,
                attrs, nil, span(start), empty)
    end

    # Rewinds to +start+ and re-reads the construct as text. Used when a tag
    # fails to parse; the bytes must still be accounted for exactly once.
    def text_from(start)
      @ss.pos = start
      text(start)
    end

    def span(start)
      @src.byteslice(start, @ss.pos - start)
    end

    ATTR_RE = /\s*([^\s=\/><]+)(?:\s*=\s*("[^"]*"|'[^']*'|[^\s>]*))?/

    def parse_attrs(str)
      attrs = {}
      s = StringScanner.new(str.to_s)
      while s.scan(ATTR_RE)
        key = s[1]
        val = s[2]
        val = val[1...-1] if val && (val.start_with?('"') || val.start_with?("'"))
        key = key.downcase unless @xml
        attrs[key] = val
      end
      attrs
    end

    def parse_doctype(raw)
      attrs = {}
      if (m = raw.match(/\A<!DOCTYPE\s+([^\s>]+)/i))
        attrs[:target] = m[1]
      end
      attrs[:public_id] = Regexp.last_match(1) if raw =~ /PUBLIC\s+"([^"]*)"/i
      attrs[:system_id] = Regexp.last_match(1) if raw =~ /(?:SYSTEM|"\s+)"([^"]*)"\s*>?\z/i
      attrs
    end
  end
end
