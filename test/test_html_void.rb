# frozen_string_literal: true

require 'test/unit'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'hpricot'

# The :html_void option applies HTML's void-element content models while
# otherwise parsing as XML.
#
# It exists for callers parsing HTML through Hpricot::XML. XML has no void
# elements, so <br> opens as a container and swallows everything after it as its
# children — which is a tree bug, not a serialization one, and the reason
# language_file_handler carried a monkey patch that suppressed `</br>` in
# Elem#output. That patch fixed the output while leaving the tree wrong, and
# broke genuine XML documents containing a <br> element.
class TestHtmlVoid < Test::Unit::TestCase
  HTML_IN_XML = '<html><body><p>line one<br>line two</p></body></html>'

  def xml(src, **opts)
    Hpricot.scan(src, { xml: true }.merge(opts))
  end

  # --- the behaviour the option exists to provide ---------------------------

  def test_a_void_element_does_not_swallow_its_siblings
    doc = xml(HTML_IN_XML, html_void: true)

    assert_empty doc.at('br').children.to_a
    assert_equal 'line two', doc.at('p').children.last.content
  end

  def test_a_void_element_gets_no_end_tag
    refute_includes xml('<p>a<br>b</p>', html_void: true).to_html, '</br>'
  end

  # The TREE matches HTML mode -- that is the point of the option. The
  # serialization deliberately does not: HTML mode writes '<br />' (XHTML
  # style, matching the C scanner), while html_void writes '<br>' as HTML5 and
  # as the source almost always did. That matters because these elements sit
  # inside translatable text, and changing '<br>' to '<br />' would alter the
  # string a translator sees and invalidate existing translations.
  def test_the_tree_matches_html_mode
    shape = lambda do |doc|
      out = +''
      walk = lambda { |n, d|
        out << ('  ' * d) << n.class.name.sub('Hpricot::', '')
        out << " #{n.name}" if n.respond_to?(:name) && n.name.is_a?(String)
        out << "\n"
        (n.respond_to?(:children) ? n.children : nil)&.each { |c| walk.call(c, d + 1) }
      }
      walk.call(doc, 0)
      out
    end

    assert_equal shape.call(Hpricot.parse(HTML_IN_XML)),
                 shape.call(xml(HTML_IN_XML, html_void: true))
  end

  # The source spelling decides, in both directions. Normalising either way
  # rewrites markup that sits inside translatable text: turning '<br>' into
  # '<br />' changes the string a translator sees and invalidates existing
  # translations, and turning '<hr />' into '<hr>' modifies a document that was
  # self-closing to begin with.
  def test_it_preserves_the_source_spelling_of_a_void_element
    assert_equal '<p>a<br>b</p>', xml('<p>a<br>b</p>', html_void: true).to_html
    assert_equal '<div><hr /></div>', xml('<div><hr /></div>', html_void: true).to_html
    assert_equal '<div><hr></div>', xml('<div><hr></div>', html_void: true).to_html
  end

  # HTML mode is unchanged and still writes the XHTML form, which is what the C
  # scanner did and what the differential harness compares against.
  def test_html_mode_serialization_is_untouched
    assert_equal '<p>a<br />b</p>', Hpricot.parse('<p>a<br>b</p>').to_html
  end

  # Every void element, not just br -- the monkey patch this replaces hardcoded
  # br and left img, hr, input and the rest emitting end tags.
  def test_every_void_element_is_covered
    %w[area base br col hr img input link meta param].each do |tag|
      doc = xml("<p>a<#{tag}>b</p>", html_void: true)

      assert_empty doc.at(tag).children.to_a, "<#{tag}> should not take children"
      refute_includes doc.to_html, "</#{tag}>", "<#{tag}> should get no end tag"
    end
  end

  def test_a_non_void_element_is_unaffected
    doc = xml('<p>a<span>b</span>c</p>', html_void: true)

    assert_equal 'b', doc.at('span').children.first.content
    assert_equal '<p>a<span>b</span>c</p>', doc.to_html
  end

  # --- what must NOT change -------------------------------------------------

  # Without the option a <br> element is an ordinary element. XLIFF, DocBook and
  # Android string resources all contain these legitimately, and dropping the
  # end tag would produce unbalanced output.
  def test_default_xml_keeps_a_real_br_element_intact
    {
      '<r><br>text</br></r>' => '<r><br>text</br></r>',
      '<r><br></br></r>' => '<r><br></br></r>',
      '<r><img>x</img></r>' => '<r><img>x</img></r>'
    }.each do |src, expected|
      assert_equal expected, xml(src).to_html, "default XML mode changed for #{src}"
    end
  end

  def test_default_xml_still_nests_children_under_a_void_name
    assert_equal 'line two', xml(HTML_IN_XML).at('br').children.first.content
  end

  # The library's core guarantee, under both settings. Preserve mode emits the
  # recorded source span, so it must be indifferent to this option.
  def test_round_tripping_is_unaffected
    sources = [HTML_IN_XML, '<r><br>text</br></r>', '<r><br/></r>', '<p>a<br>b</p>',
               '<r><img src="x">alt</img></r>', '<x><hr></x>']

    sources.each do |src|
      [{}, { html_void: true }].each do |opts|
        assert_equal src, xml(src, **opts).to_original_html,
                     "#{src} did not round-trip with #{opts.inspect}"
      end
    end
  end

  def test_the_void_set_comes_from_element_content
    # Derived rather than hardcoded, so it cannot drift from HTML mode.
    Hpricot::TreeBuilder::VOID_TAGS.each_key do |tag|
      assert_equal :EMPTY, Hpricot::ElementContent[tag],
                    "#{tag} is in VOID_TAGS but is not :EMPTY in ElementContent"
    end
    assert_includes Hpricot::TreeBuilder::VOID_TAGS, 'br'
    refute_includes Hpricot::TreeBuilder::VOID_TAGS, 'p'
  end
end
