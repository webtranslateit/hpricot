# Ragel grammar (historical)

These are the ragel sources the C scanner was generated from, kept as the
specification the pure-Ruby scanner in `lib/hpricot/scanner.rb` was ported from.
They are **not** built and nothing requires ragel any more.

Where the Ruby scanner deliberately departs from this grammar, it is because
the C implementation lost data and byte-identical round-tripping is the
guarantee this library exists to provide:

* An unterminated `<!--` comment or `<![CDATA[` section keeps its source span.
  The C scanner dropped the opening delimiter, so `<p>a</p><!-- never closed`
  came back four bytes short as `<p>a</p> never closed`.
* An unterminated attribute quote round-trips. The C scanner prepended the tag
  name to the resulting text node.

To reproduce the old behaviour for comparison, check out the tag
`pre-pure-ruby-scanner`, build `ext/hpricot_scan` and `ext/fast_xs`, and point
`HPRICOT_LEGACY_TREE` at that checkout; `test/test_differential.rb` will then
compare the two implementations. See that file for details.
