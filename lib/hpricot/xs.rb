# frozen_string_literal: true

# Pure-Ruby replacement for the fast_xs C extension.
#
# This is a BEHAVIOUR-PRESERVING port. It reproduces what ext/fast_xs/fast_xs.c
# does, including two things that are arguably wrong, because the differential
# harness requires byte-for-byte parity and changing behaviour belongs in a
# separate commit from replacing an implementation:
#
#   * XML-invalid control characters become "*" rather than being escaped or
#     dropped. Tab, newline and carriage return pass through untouched.
#   * In BINARY strings the CP-1252 range is mapped to Unicode, but the five
#     bytes CP-1252 leaves undefined (129, 141, 143, 144, 157) become "*"
#     rather than the numeric reference fast_xs.c's own comments claim. That is
#     the `#define p(x) (x-128)` bug at fast_xs.c:32.
#
# Note that "'" is deliberately NOT escaped, matching the C version.
class String
  XS_ESCAPES = { '&' => '&amp;', '<' => '&lt;', '>' => '&gt;', '"' => '&quot;' }.freeze

  # Control characters that are invalid in XML. 9 (tab), 10 (LF) and 13 (CR)
  # are valid and pass through.
  XS_INVALID_CONTROL = ((0..8).to_a + [11, 12] + (14..31).to_a).freeze

  # CP-1252 codepoints for bytes 128-159, which is where CP-1252 differs from
  # Latin-1. nil marks the five undefined positions, which become "*".
  XS_CP1252 = [
    0x20AC, nil,    0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, nil,    0x017D, nil,
    nil,    0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, nil,    0x017E, 0x0178
  ].freeze

  def fast_xs
    binary = !encoding.ascii_compatible? || encoding == Encoding::BINARY
    out = +''

    if binary || !valid_encoding?
      each_byte { |b| out << xs_byte(b) }
    else
      each_char { |c| out << xs_char(c) }
    end

    out
  end

  private

  def xs_char(char)
    return XS_ESCAPES[char] if XS_ESCAPES.key?(char)

    ord = char.ord
    return '*' if XS_INVALID_CONTROL.include?(ord)
    return char if ord < 128

    "&##{ord};"
  end

  # Single bytes, interpreted as CP-1252 above 127 the way fast_xs.c does.
  def xs_byte(byte)
    char = byte.chr
    return XS_ESCAPES[char] if XS_ESCAPES.key?(char)
    return '*' if XS_INVALID_CONTROL.include?(byte)
    return char if byte < 128

    if byte < 160
      cp = XS_CP1252[byte - 128]
      return cp.nil? ? '*' : "&##{cp};"
    end

    "&##{byte};"
  end
end
