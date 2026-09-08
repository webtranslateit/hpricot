# frozen_string_literal: true

require 'test/unit'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'hpricot/nodes'

class TestNodes < Test::Unit::TestCase
  def test_text_aliases_name_slot
    t = Hpricot::Text.allocate
    t.content = 'hello'
    assert_equal 'hello', t.content
    assert_equal 'hello', t.raw_string
    assert_equal 'hello', t.name
    t.clear_raw
    assert_nil t.content
  end

  def test_elem_has_eight_slots
    e = Hpricot::Elem.allocate
    e.name = 'div'
    e.raw_attributes = { 'id' => 'x' }
    e.raw_string = '<div id="x">'
    e.children = []
    assert_equal 'div', e.name
    assert_equal({ 'id' => 'x' }, e.raw_attributes)
    assert_equal '<div id="x">', e.raw_string
    e.clear_raw
    assert_nil e.raw_string
  end

  def test_doctype_maps_accessors_onto_raw_attributes
    d = Hpricot::DocType.allocate
    d.raw_attributes = {}
    d.target = 'html'
    d.public_id = '-//W3C//DTD HTML 4.01//EN'
    d.system_id = 'http://www.w3.org/TR/html4/strict.dtd'
    assert_equal 'html', d.target
    assert_equal '-//W3C//DTD HTML 4.01//EN', d.public_id
    assert_equal 'http://www.w3.org/TR/html4/strict.dtd', d.system_id
  end

  def test_xmldecl_maps_accessors_onto_raw_attributes
    x = Hpricot::XMLDecl.allocate
    x.raw_attributes = {}
    x.version = '1.0'
    x.encoding = 'utf-8'
    x.standalone = 'yes'
    assert_equal '1.0', x.version
    assert_equal 'utf-8', x.encoding
    assert_equal 'yes', x.standalone
  end

  def test_procins_content_is_the_raw_attributes_slot
    p = Hpricot::ProcIns.allocate
    p.target = 'xml-stylesheet'
    p.content = 'href="a.css"'
    assert_equal 'xml-stylesheet', p.target
    assert_equal 'href="a.css"', p.content
  end

  def test_bogus_etag_raw_string_is_the_raw_attributes_slot
    b = Hpricot::BogusETag.allocate
    b.name = 'div'
    # The C extension never defines BogusETag#raw_string= (only the generic
    # #raw_attributes= from structAttr), so that is the only way to set it.
    b.raw_attributes = '</div >'
    assert_equal '</div >', b.raw_string
    b.clear_raw
    assert_nil b.raw_string
  end
end
