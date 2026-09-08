# frozen_string_literal: true

require 'test/unit'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'hpricot'

# The encoding a parsed node's strings carry. The differential harness
# deliberately compares bytes rather than encoding tags, so this behaviour is
# asserted here instead.
class TestEncoding < Test::Unit::TestCase
  def content_of(src)
    Hpricot::XML(src).at('s').children[0].content
  end

  # A BINARY source says nothing about what its bytes mean, which is what
  # File.binread and Zip::File#read return. Tag it default_external, as the C
  # scanner did for every input: language_file_handler reads .docx parts out of
  # a zip and hands them to HTMLEntities#decode, which raises on ASCII-8BIT.
  def test_binary_source_is_tagged_default_external
    src = %(<r><s>cafÃ©</s></r>).dup.force_encoding(Encoding::ASCII_8BIT)
    got = content_of(src)
    assert_equal Encoding.default_external, got.encoding
    assert got.valid_encoding?
  end

  def test_utf8_source_stays_utf8
    got = content_of('<r><s>café</s></r>')
    assert_equal Encoding::UTF_8, got.encoding
    assert got.valid_encoding?
  end

  # Where this departs from the C scanner, which tagged every node
  # default_external regardless and so produced UTF-8-labelled strings that
  # failed valid_encoding? for any non-UTF-8 document.
  def test_declared_encoding_is_believed
    got = content_of('<r><s>café</s></r>'.encode('ISO-8859-1'))
    assert_equal Encoding::ISO_8859_1, got.encoding
    assert got.valid_encoding?
  end

  # The C scanner raised EncodingError here: rb_enc_find_index returns -1 for an
  # unknown name and the result was passed to rb_enc_associate_index unchecked.
  def test_unknown_declared_encoding_does_not_raise
    assert_nothing_raised do
      Hpricot::XML('<r><s>hi</s></r><?xml version="1.0" encoding="pwn"?>')
    end
  end

  def test_invalid_byte_sequence_does_not_raise
    # A lone \xE9 is not valid UTF-8. Written as an escape in a double-quoted
    # string so the bytes really are invalid: the previous version of this test
    # used a literal e-acute in a UTF-8 source file, so force_encoding(UTF_8)
    # was a no-op and it asserted nothing about its subject.
    src = "<r><s>caf\xE9</s></r>".dup.force_encoding(Encoding::UTF_8)
    refute src.valid_encoding?, 'fixture must actually contain invalid bytes'
    assert_nothing_raised { Hpricot::XML(src) }
  end
end
