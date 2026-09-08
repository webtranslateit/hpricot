# frozen_string_literal: true

require 'test/unit'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'hpricot/scanner'

class TestScanner < Test::Unit::TestCase
  def scan(src, **opts)
    Hpricot::Scanner.new(src, **opts).tokens
  end

  def test_plain_text
    toks = scan('hello')
    assert_equal 1, toks.length
    assert_equal :text, toks[0].kind
    assert_equal 'hello', toks[0].raw
  end

  def test_comment_keeps_raw
    toks = scan('<!-- hi -->')
    assert_equal :comment, toks[0].kind
    assert_equal '<!-- hi -->', toks[0].raw
    assert_equal ' hi ', toks[0].content
  end

  def test_cdata_keeps_raw
    toks = scan('<![CDATA[x < y]]>')
    assert_equal :cdata, toks[0].kind
    assert_equal '<![CDATA[x < y]]>', toks[0].raw
    assert_equal 'x < y', toks[0].content
  end

  def test_xmldecl
    toks = scan('<?xml version="1.0" encoding="utf-8"?>')
    assert_equal :xmldecl, toks[0].kind
    assert_equal '1.0', toks[0].attrs['version']
    assert_equal 'utf-8', toks[0].attrs['encoding']
  end

  def test_procins
    toks = scan('<?xml-stylesheet href="a.css"?>')
    assert_equal :procins, toks[0].kind
    assert_equal 'xml-stylesheet', toks[0].name
    assert_equal 'href="a.css"', toks[0].content
  end

  def test_doctype
    toks = scan('<!DOCTYPE html>')
    assert_equal :doctype, toks[0].kind
    assert_equal '<!DOCTYPE html>', toks[0].raw
  end

  # Fidelity invariant: concatenating every raw span reproduces the input.
  def test_raw_spans_reassemble_exactly
    src = 'a<!-- c --><![CDATA[d]]><?pi x?>b'
    assert_equal src, scan(src).map(&:raw).join
  end

  # Liberality: an unterminated comment must not raise.
  def test_unterminated_comment_does_not_raise
    toks = scan('<!-- never closed')
    assert_equal '<!-- never closed', toks.map(&:raw).join
  end

  def test_start_tag_with_attributes
    toks = scan('<div id="a" class=b>')
    assert_equal :stag, toks[0].kind
    assert_equal 'div', toks[0].name
    assert_equal 'a', toks[0].attrs['id']
    assert_equal 'b', toks[0].attrs['class']
    assert_equal '<div id="a" class=b>', toks[0].raw
  end

  def test_empty_tag
    toks = scan('<br />')
    assert_equal :emptytag, toks[0].kind
    assert_equal 'br', toks[0].name
  end

  def test_end_tag
    toks = scan('</div>')
    assert_equal :etag, toks[0].kind
    assert_equal 'div', toks[0].name
  end

  # Attribute values are stored undecoded — this is the fidelity requirement
  # from language_file_handler#691.
  def test_entities_in_attribute_values_are_not_decoded
    toks = scan('<a title="a&#8230;b&quot;c">')
    assert_equal 'a&#8230;b&quot;c', toks[0].attrs['title']
  end

  def test_attribute_names_downcased_in_html_mode_only
    assert_equal 'x', scan('<a HREF="x">')[0].attrs['href']
    assert_equal 'x', scan('<a HREF="x">', xml: true)[0].attrs['HREF']
  end

  def test_unterminated_tag_does_not_raise
    src = '<div id="a"'
    assert_equal src, scan(src).map(&:raw).join
  end

  def test_full_document_reassembles_exactly
    src = %(<?xml version="1.0"?>\n<r a="1">\n  <s>x&#8230;</s>\n</r>\n)
    assert_equal src, scan(src, xml: true).map(&:raw).join
  end

  # --- Byte-fidelity property test -------------------------------------
  #
  # The single invariant the whole port exists to preserve: every byte of
  # the input appears in exactly one token's raw span, for ANY input,
  # however malformed.
  REASSEMBLY_INPUTS = [
    '',
    '<',
    '<<<',
    '<a',
    '<a b',
    '<a b=',
    '<a b="',
    '<a b=c d>',
    '</',
    '</>',
    '<!--',
    '<!-- unterminated',
    '<!-- has -- inside -->',
    '<!--nested<!--comment-->tail',
    '<![CDATA[',
    '<![CDATA[unterminated',
    '<![CDATA[x]]y]]>',
    '<?',
    '<?xml',
    '<?xml version="1.0"?>',
    '<!',
    '<!DOCTYPE',
    '<!DOCTYPE html',
    '<a></b></a>',
    '&#99999999999;',
    "\x00<a>",
    '<a title="a&#8230;b&quot;c">',
    "<p>café … 日本語</p>",
    'plain text, no markup at all',
    '<><><>',
    "<a\nb\n=\n'c'\n>",
    '<!--comment--><tag>text</tag><!DOCTYPE x>'
  ].freeze

  def test_reassembly_invariant_over_varied_and_malformed_inputs
    REASSEMBLY_INPUTS.each do |src|
      [{}, { xml: true }].each do |opts|
        toks = scan(src, **opts)
        joined = toks.map(&:raw).join
        assert_equal src, joined,
                     "reassembly failed for #{src.inspect} (opts=#{opts.inspect})"
      end
    end
  end

  # --- No-raise property test -------------------------------------------
  #
  # The scanner must never raise, on any input, including every truncated
  # prefix of a realistic document.
  def test_never_raises_on_truncated_prefixes_of_a_real_document
    src = File.binread(File.expand_path('files/basic.xhtml', __dir__))
    (0..src.bytesize).each do |i|
      prefix = src.byteslice(0, i)
      assert_nothing_raised("raised on prefix of length #{i}") do
        scan(prefix)
      end
    end
  end

  # --- UTF-8 fidelity -----------------------------------------------------
  def test_utf8_content_reassembles_exactly_using_byte_offsets
    src = '<p>café … 日本語</p>'
    toks = scan(src)
    assert_equal src, toks.map(&:raw).join
    text_tok = toks.find { |t| t.kind == :text }
    assert_equal 'café … 日本語', text_tok.raw
  end

  # All four DOCTYPE shapes, verified against the C scanner. The SYSTEM form
  # regressed once because the pattern required SYSTEM to be followed
  # immediately by a quote, which broke the JavaXml fixture's
  # <!DOCTYPE properties SYSTEM "...">.
  def test_doctype_external_identifiers
    assert_equal({ target: 'html' },
                 scan('<!DOCTYPE html>')[0].attrs)

    assert_equal({ target: 'properties',
                   system_id: 'http://java.sun.com/dtd/properties.dtd' },
                 scan('<!DOCTYPE properties SYSTEM "http://java.sun.com/dtd/properties.dtd">')[0].attrs)

    assert_equal({ target: 'html', public_id: '-//W3C//DTD HTML 4.01//EN' },
                 scan('<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01//EN">')[0].attrs)

    assert_equal({ target: 'html',
                   public_id: '-//W3C//DTD XHTML 1.0 Strict//EN',
                   system_id: 'http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd' },
                 scan('<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" ' \
                      '"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">')[0].attrs)
  end

  # Constructs that must NOT be recognised, because the grammar requires more
  # than the opening delimiter. Each of these was accepted at some point during
  # the port, and each produced a node whose to_html either deleted the source
  # bytes or invented ones that were never there. All verified against the C
  # scanner.
  def test_malformed_constructs_are_text
    {
      # hpricot_common.rl:32 EndTag = "</" NameCap space* ">"
      '</>'                   => 'empty end-tag name',
      '</ >'                  => 'end tag with no name',
      '</x'                   => 'end tag with no closing >',
      # hpricot_common.rl:45 DocType requires space, a Name and a ">"
      '<!DOCTYPE'             => 'doctype with nothing after it',
      '<!DOCTYPE html'        => 'doctype with no closing >',
      '<!DOCTYPEhtml>'        => 'doctype with no space before the name',
      # hpricot_common.rl:46 StartXmlProcIns = "<?" Name space+
      '<?x?>'                 => 'PI with no space after the name',
      '<?x>'                  => 'PI with no space and a bare terminator',
      '<?x'                   => 'PI with no terminator',
      '<?xml version="1.0"'   => 'XML declaration with no terminator'
    }.each do |src, why|
      toks = scan(src, xml: true)
      assert_equal %i[text], toks.map(&:kind).uniq, "#{src.inspect} (#{why}) should be text"
      assert_equal src, toks.map(&:raw).join, "#{src.inspect} must still round-trip"
    end
  end

  # An internal DTD subset contains '>' characters of its own, so the doctype
  # cannot simply stop at the first one.
  def test_doctype_internal_subset_is_consumed_whole
    src = %(<!DOCTYPE n [<!ENTITY x "y">]><n>z</n>)
    toks = scan(src, xml: true)
    assert_equal :doctype, toks[0].kind
    assert_equal '<!DOCTYPE n [<!ENTITY x "y">]>', toks[0].raw
    assert_equal src, toks.map(&:raw).join
  end

  # Trailing whitespace belongs to a PI's content: the C scanner stores
  # "echo 1; " for "<?php echo 1; ?>", and to_html re-emits it.
  def test_procins_keeps_trailing_whitespace_in_content
    assert_equal 'echo 1; ', scan('<?php echo 1; ?>', xml: true)[0].content
    assert_equal 'a  ',      scan('<?x  a  ?>', xml: true)[0].content
  end
end
