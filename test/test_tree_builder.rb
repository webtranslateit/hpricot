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

  # --- Task 7: HTML implicit closing --------------------------------------

  def test_li_implicitly_closes_li
    doc = build('<ul><li>a<li>b</ul>')
    ul = doc.children[0]
    assert_equal 2, ul.children.count { |c| c.is_a?(Hpricot::Elem) && c.name == 'li' }
    assert_equal ['li', 'li'], ul.children.select { |c| c.is_a?(Hpricot::Elem) }.map(&:name)
  end

  def test_p_implicitly_closes_p
    doc = build('<div><p>a<p>b</div>')
    div = doc.children[0]
    assert_equal 2, div.children.count { |c| c.is_a?(Hpricot::Elem) && c.name == 'p' }
  end

  def test_html_mode_downcases_tag_names
    doc = build('<DIV><SPAN>x</SPAN></DIV>')
    assert_equal 'div', doc.children[0].name
  end

  def test_nested_tags_still_nest
    doc = build('<div><span>x</span></div>')
    div = doc.children[0]
    assert_equal 'span', div.children[0].name
  end

  # --- Additional HTML implicit-close cases, verified against the C scanner
  # (ruby -Ilib -Iext/hpricot_scan -Iext/fast_xs -e '...') per the task's
  # explicit request to validate close_implied against the real
  # implementation rather than the plan's simplified sketch.

  def test_td_implicitly_closes_td_across_a_tr
    doc = build('<table><tr><td>a<td>b</tr></table>')
    tr = doc.children[0].children[0]
    assert_equal ['td', 'td'], tr.children.select { |c| c.is_a?(Hpricot::Elem) }.map(&:name)
  end

  # <p> does not exclude <div> nor does it list it as allowed content, so an
  # unmatched key produces "no opinion" and the walk falls back to the
  # current focus: the C scanner nests <div> INSIDE <p> rather than closing
  # it. (Real browsers close <p> before a block-level child, but hpricot's
  # ElementContent-driven algorithm does not encode that rule for <div>.)
  def test_div_nests_inside_p_rather_than_closing_it
    doc = build('<p><div>x</div></p>')
    p = doc.children[0]
    assert_equal 'p', p.name
    assert_equal 'div', p.children[0].name
  end

  # <b> permits <i> (true), so <i> nests inside <b> without closing it, and
  # the mismatched </b> then closes both (the C scanner's O(n) tag search
  # matches the nearest open <b> and drops everything above it, giving the
  # </i> an unmatched close tag of its own -- it becomes a BogusETag).
  def test_mismatched_end_tags_close_the_open_ancestor_and_its_descendants
    doc = build('<b><i>x</b></i>')
    b = doc.children[0]
    assert_equal 'b', b.name
    assert_equal 'i', b.children[0].name
    assert_kind_of Hpricot::BogusETag, doc.children[1]
  end

  def test_unmatched_end_tag_becomes_bogus_etag_in_html_mode
    doc = build('<div>text</q>after</div>')
    div = doc.children[0]
    assert_include div.children.map(&:class), Hpricot::BogusETag
  end

  # <a> excludes nested <a> (ElementExclusions), so a second <a> closes the
  # first and becomes its sibling.
  def test_a_implicitly_closes_a
    doc = build('<div><a>one<a>two</a></a></div>')
    div = doc.children[0]
    as = div.children.select { |c| c.is_a?(Hpricot::Elem) && c.name == 'a' }
    assert_equal 2, as.length
  end

  # Verified against the C scanner (button excludes "a" -- ElementExclusions
  # -- while span's content model allows it): the walk must consider the
  # *entire* ancestor chain, not just the nearest ancestor with an opinion.
  # <span> alone would permit the second <a> to close the first and become
  # its sibling, but the outer <button>'s exclusion of <a> cancels that
  # permission, so the C scanner nests the second <a> straight inside the
  # first with no implicit close at all.
  def test_an_outer_ancestors_exclusion_overrides_a_closer_ancestors_inclusion
    doc = build('<button><span><a>text<a>text2</a></a></span></button>')
    span = doc.children[0].children[0]
    assert_equal 'a', span.children[0].name
    inner_a = span.children[0].children.find { |c| c.is_a?(Hpricot::Elem) }
    assert_equal 'a', inner_a.name
  end

  # XML mode must never apply implicit closing, even for names that collide
  # with HTML's implicit-close tags.
  def test_xml_mode_does_not_implicitly_close
    doc = build('<ul><li>a<li>b</li></li></ul>', xml: true)
    ul = doc.children[0]
    li1 = ul.children[0]
    assert_equal 'li', li1.name
    li2 = li1.children.find { |c| c.is_a?(Hpricot::Elem) }
    assert_equal 'li', li2.name
  end
end
