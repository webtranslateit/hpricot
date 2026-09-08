# frozen_string_literal: true

require 'test/unit'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

# Deliberately avoid `require 'hpricot'`: that loads the C extension
# (ext/hpricot_scan/hpricot_scan.bundle), which still defines Elem, Text,
# Comment, CData, DocType, ProcIns, XMLDecl, BogusETag and Doc today. Since
# hpricot/nodes.rb defines those same names as plain-Ruby classes with a
# different superclass (ElemNode/AttrNode/BasicNode), loading both raises
# `TypeError: superclass mismatch` the moment nodes.rb is required.
#
# lib/hpricot.rb is not modified by this task (that is Task 9's job), so it
# is safe to require the individual library files that the tree builder
# needs directly. This also happens to give us `to_original_html` for a real
# byte-identical round-trip assertion (see test_round_trips_byte_identically
# below), without pulling in the C scanner or the fast_xs C extension:
#
#   * hpricot/tag.rb, hpricot/modules.rb and hpricot/traverse.rb reopen the
#     node classes to add #output/#to_html/#to_original_html; none of them
#     `require` a native extension.
#   * hpricot/tag.rb's reopened classes override #initialize to take
#     positional constructor args (e.g. `Text.new(content)`), which is
#     incompatible with the tree builder's `Klass.new` + setters
#     construction. The tree builder therefore builds nodes with
#     `Klass.allocate`, exactly like the C scanner did (it never invoked the
#     Ruby-level #initialize either — it allocated structs directly).
require 'hpricot/nodes'
require 'hpricot/htmlinfo'
require 'hpricot/scanner'
require 'hpricot/tree_builder'
require 'hpricot/tag'
require 'hpricot/modules'
require 'hpricot/traverse'

class TestTreeBuilder < Test::Unit::TestCase
  def build(src, **opts)
    Hpricot::TreeBuilder.new(Hpricot::Scanner.new(src, **opts).tokens, **opts).document
  end

  def test_nests_elements
    doc = build('<r><a>x</a></r>', xml: true)
    r = doc.children[0]
    assert_equal 'r', r.name
    assert_equal 'a', r.children[0].name
    assert_equal 'x', r.children[0].children[0].content
  end

  def test_sets_parent_pointers
    doc = build('<r><a>x</a></r>', xml: true)
    r = doc.children[0]
    assert_same doc, r.parent
    assert_same r, r.children[0].parent
  end

  def test_empty_tag_has_no_children
    doc = build('<r><a/></r>', xml: true)
    a = doc.children[0].children[0]
    assert_equal 'a', a.name
    assert(a.children.nil? || a.children.empty?)
  end

  def test_unmatched_end_tag_becomes_bogus_etag
    doc = build('<r></q></r>', xml: true)
    kinds = doc.children[0].children.map(&:class)
    assert_include kinds, Hpricot::BogusETag
  end

  def test_xml_mode_preserves_tag_case
    doc = build('<Root><Child/></Root>', xml: true)
    assert_equal 'Root', doc.children[0].name
  end

  # The plan's original assertion was `to_html(:preserve => true)`, mirroring
  # upstream hpricot's `to_html(opts = {})`. In *this* fork, `to_html` (from
  # hpricot/traverse.rb) takes no arguments at all -- `doc.to_html(:preserve
  # => true)` raises ArgumentError even against the C-scanner-built tree, so
  # that is not a scanner-port regression to work around. This fork already
  # has the equivalent entry point, `to_original_html`, which is exactly
  # `output(+"", :preserve => true)`; using it keeps this a real,
  # non-fake byte-identical assertion rather than falling back to comparing
  # raw token spans.
  def test_round_trips_byte_identically
    src = %(<?xml version="1.0"?>\n<r a="1">\n  <s>x&#8230;&quot;y</s>\n</r>\n)
    assert_equal src, build(src, xml: true).to_original_html
  end
end
