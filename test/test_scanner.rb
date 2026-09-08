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
end
