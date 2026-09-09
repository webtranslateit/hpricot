# frozen_string_literal: true

require 'test/unit'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'hpricot'

# The :void_elements option names which tag names are void, instead of taking
# HTML's whole list the way :html_void does.
#
# Void-ness belongs to the document type, not to the tag name. A caller round
# tripping translatable text through Hpricot::XML needs <br> not to swallow the
# rest of its parent and not to acquire a '</br>', but its documents are XML
# vocabularies that reuse other HTML names for containers -- TYPO3's locallang
# XML has a <meta> holding <type> and <description>. Applying HTML's list to
# those drops both the children and the end tag, so the caller names the one
# tag it means.
class TestVoidElements < Test::Unit::TestCase
  def xml(src, **opts)
    Hpricot.scan(src, { xml: true }.merge(opts))
  end

  # --- the behaviour the option exists to provide ---------------------------

  def test_a_named_element_is_void
    doc = xml('<p>a<br>b</p>', void_elements: %w[br])

    assert_empty doc.at('br').children.to_a
    assert_equal 'b', doc.at('p').children.last.content
    refute_includes doc.to_html, '</br>'
  end

  def test_an_unnamed_element_stays_an_ordinary_container
    doc = xml('<p>a<img src="i">b</p>', void_elements: %w[br])

    assert_equal 'b', doc.at('img').children.first.content
    assert_includes doc.to_html, '</img>'
  end

  # The case html_void cannot serve: an XML vocabulary whose <meta> is a
  # container. html_void drops its children and its end tag; naming only 'br'
  # leaves it alone.
  def test_a_container_sharing_a_void_html_name_survives
    src = '<root><meta type="array"><type>database</type></meta><p>a<br>b</p></root>'

    assert_equal src, xml(src, void_elements: %w[br]).to_html
    refute_includes xml(src, html_void: true).to_html, '</meta>'
  end

  # --- the set as given -----------------------------------------------------

  def test_naming_every_html_void_tag_matches_html_void
    src = '<p>a<br>b<img src="i">c<hr>d</p>'
    named = xml(src, void_elements: %w[br img hr input meta link area base col embed param source track wbr])

    assert_equal xml(src, html_void: true).to_html, named.to_html
  end

  def test_an_explicit_empty_set_makes_nothing_void
    src = '<p>a<br>b</p>'

    assert_equal xml(src).to_html, xml(src, void_elements: []).to_html
    assert_includes xml(src, void_elements: []).to_html, '</br>'
  end

  def test_an_explicit_set_overrides_html_void
    doc = xml('<p>a<br>b<img src="i">c</p>', html_void: true, void_elements: %w[br])

    assert_empty doc.at('br').children.to_a
    assert_includes doc.to_html, '</img>'
  end

  def test_a_bare_name_is_accepted_as_a_one_element_set
    refute_includes xml('<p>a<br>b</p>', void_elements: 'br').to_html, '</br>'
  end

  def test_symbols_are_accepted
    refute_includes xml('<p>a<br>b</p>', void_elements: [:br]).to_html, '</br>'
  end

  # XML is case sensitive and this option is for XML mode, so the set is
  # matched exactly rather than folded.
  def test_names_are_matched_exactly
    assert_includes xml('<p>a<BR>b</p>', void_elements: %w[br]).to_html, '</BR>'
  end

  # --- the source spelling still decides ------------------------------------

  def test_the_source_spelling_is_preserved_in_both_directions
    assert_equal '<p>a<br>b</p>', xml('<p>a<br>b</p>', void_elements: %w[br]).to_html
    assert_equal '<p>a<br />b</p>', xml('<p>a<br />b</p>', void_elements: %w[br]).to_html
  end

  # --- propagation ----------------------------------------------------------

  # The document's options are stored and reused by Traverse#make, so a
  # fragment assigned with inner_html= parses under the same set. This is the
  # path that carries a translation into an existing document.
  def test_the_option_reaches_fragments_parsed_into_the_document
    doc = xml('<root><msg></msg></root>', void_elements: %w[br])
    doc.at('msg').inner_html = 'line one<br>line two'

    assert_equal '<root><msg>line one<br>line two</msg></root>', doc.to_html
  end

  def test_hpricot_xml_accepts_the_option
    refute_includes Hpricot::XML('<p>a<br>b</p>', void_elements: %w[br]).to_html, '</br>'
  end

  # --- no effect outside XML mode ------------------------------------------

  # HTML mode already has ElementContent for this, and it is not narrowable:
  # the option only ever adds to XML mode, where nothing is void to begin with.
  def test_html_mode_is_unaffected
    src = '<p>a<br>b<img src="i">c</p>'

    assert_equal Hpricot.parse(src).to_html, Hpricot.parse(src, void_elements: %w[br]).to_html
  end
end
