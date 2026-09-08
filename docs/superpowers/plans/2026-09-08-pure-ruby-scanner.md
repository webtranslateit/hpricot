# Pure-Ruby Scanner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-ruby:subagent-driven-development (recommended) or superpowers-ruby:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace hpricot's C/ragel scanner and its parallel Java implementation with a pure-Ruby scanner that preserves byte-identical round-tripping and hpricot's liberal parsing behaviour, eliminating the entire memory-safety defect class.

**Architecture:** A `StringScanner`-based tokenizer emits tokens that each retain their exact source byte span. A tree builder turns that token stream into the existing `Hpricot::Doc` node graph, reusing the current HTML implicit-close rules from `ElementContent`. Node classes become plain Ruby objects with the same slots the C structs had, so `traverse.rb`, `elements.rb`, `builder.rb` and downstream consumers are untouched. Fidelity comes from *not decoding*: raw spans are stored verbatim and emitted unchanged for unmodified nodes, which is exactly how the C version achieves it.

**Tech Stack:** Ruby >= 3.2, `strscan` (stdlib, C-backed), Test::Unit (existing suite), no native extensions.

**Non-goals:** Porting `hpricot_css.rl` (dead — `Elements#search` uses Ruby regex in `elements.rb`; nothing in `lib/` calls `Hpricot.css`) and `fast_xs` beyond a Ruby equivalent. `Hpricot.scan` with a block is dropped (it segfaults today and has no callers).

---

## Background: what you are replacing

`ext/hpricot_scan/hpricot_scan.rl` is a ragel state machine (~900 lines of grammar, ~500 lines of hand-written C actions). `Hpricot.scan(input, opts)` is its only entry point that matters — `Hpricot()`, `Hpricot.parse` and `Hpricot::XML` all funnel into it via `Hpricot.make` (`lib/hpricot/parse.rb:31-38`).

**Do not regenerate the `.c` files with ragel.** `hpricot_scan.rl:23` declares `hpricot_css` with 5 parameters while the real definition takes 4; the fix was applied only to the generated `.c`. Regenerating reintroduces a build failure. This plan deletes both, so the divergence stops mattering.

### The node model you must reproduce exactly

The C code stores node state in a malloc'd `VALUE` array behind `Struct`-like classes (`hpricot_scan.rl:853-861`). Three shapes:

| Struct | Slots | Classes |
|---|---|---|
| `structBasic` (2) | `name`, `parent` | `Text`, `Comment`, `CData` |
| `structAttr` (3) | `name`, `parent`, `raw_attributes` | `DocType`, `ProcIns`, `XMLDecl`, `BogusETag` |
| `structElem` (8) | `name`, `parent`, `raw_attributes`, `etag`, `raw_string`, `allowed`, `tagno`, `children` | `Doc`, `Elem` |

Aliases layered on top (`hpricot_scan.rl:863-899`) — these are the public API and must survive:

- `Text#content` / `#content=` / `#raw_string` / `#clear_raw` → the `name` slot
- `Comment#content`, `CData#content` (+ `=`) → the `name` slot
- `DocType#raw_string` / `#clear_raw` → `name` slot; `#target`, `#public_id`, `#system_id` (+ `=`) → keys in `raw_attributes`
- `XMLDecl#raw_string` / `#clear_raw` → `name` slot; `#version`, `#encoding`, `#standalone` (+ `=`) → keys in `raw_attributes`
- `ProcIns#target` (+ `=`) → `name` slot; `#content` (+ `=`) → the `raw_attributes` slot (holds a String here, not a Hash)
- `BogusETag#raw_string` / `#clear_raw` → the `raw_attributes` slot (holds a String)
- `Elem#clear_raw` → clears `raw_string`

`allowed` holds the `ElementContent` entry for the tag (used for HTML implicit-close). `tagno` holds `tag_name.hash`.

### Scanner options

Only three are read (`hpricot_scan.rl:524-526`): `:xml`, `:xhtml_strict`, `:fixup_tags`. `Hpricot::XML` sets `:xml => true`, which disables attribute-name downcasing and all HTML implicit-close logic.

### Baseline to beat

```
$ ruby -Ilib -Iext/hpricot_scan -Itest test/test_parser.rb
57 tests, 126 assertions, 3 failures, 2 errors
```

The 2 errors are `Fixnum` (`elements.rb:68`, removed in Ruby 3.2). The 3 failures are **nondeterministic** — they come from an uninitialized read in the C scanner and vary run to run. Fix `Fixnum` in Task 1 so you have a stable target; after the port the suite must be **0 failures, 0 errors, deterministically across 20 consecutive runs**.

---

## File Structure

**Create:**
- `lib/hpricot/nodes.rb` — the nine node classes, replacing the C structs
- `lib/hpricot/scanner.rb` — `StringScanner` tokenizer, emits tokens with raw spans
- `lib/hpricot/tree_builder.rb` — token stream → `Hpricot::Doc`, incl. HTML implicit-close
- `lib/hpricot/xs.rb` — Ruby replacement for the `fast_xs` C extension
- `test/test_differential.rb` — old-vs-new oracle harness
- `test/test_scanner.rb` — unit tests for the tokenizer
- `.github/workflows/ci.yml` — CI matrix

**Modify:**
- `lib/hpricot.rb:15-26` — require the new files instead of `hpricot_scan` / `fast_xs`
- `lib/hpricot/elements.rb:68` — `Fixnum` → `Integer`
- `hpricot.gemspec` — drop `extensions`, add `required_ruby_version`, fix metadata
- `Rakefile` — drop `Rake::ExtensionTask`, the mswin32 cross-compile, the Java tasks

**Delete (Task 13, last):**
- `ext/` entirely, `setup.rb`, `.travis.yml`
- Keep `ext/hpricot_scan/hpricot_scan.rl` + `hpricot_common.rl` moved to `docs/grammar/` until Task 12 passes — they are the spec you are translating.

---

## Task 1: Stabilise the baseline

**Files:**
- Modify: `lib/hpricot/elements.rb:68`

- [ ] **Step 1: Run the suite and record the failure set**

```bash
cd /Users/edouard/code/github/hpricot
ruby -Ilib -Iext/hpricot_scan -Itest test/test_parser.rb 2>&1 | tail -3
```

Expected: `57 tests, 126 assertions, 3 failures, 2 errors` (failure count varies; errors are always 2).

- [ ] **Step 2: Fix the Ruby 3.2 removal**

In `lib/hpricot/elements.rb:68`, change:

```ruby
      if expr.kind_of? Fixnum
```

to:

```ruby
      if expr.kind_of? Integer
```

- [ ] **Step 3: Verify the two errors are gone**

```bash
ruby -Ilib -Iext/hpricot_scan -Itest test/test_parser.rb 2>&1 | tail -3
```

Expected: `0 errors`. Failures still vary (that is the C bug you are removing).

- [ ] **Step 4: Commit**

```bash
git add lib/hpricot/elements.rb
git commit -m "Replace Fixnum with Integer

Fixnum was removed in Ruby 3.2, making Elements#at and its % alias
raise NameError on every call regardless of argument type."
```

---

## Task 2: Differential harness

Build the safety net before touching the parser. It compares the installed C scanner against the new Ruby one on a corpus, asserting byte-identical `to_html` output.

**Files:**
- Create: `test/test_differential.rb`
- Create: `test/corpus/.gitkeep`

- [ ] **Step 1: Write the harness**

Create `test/corpus/.gitkeep` (empty file), then create `test/differential_helper.rb`:

```ruby
# frozen_string_literal: true

# Compares the legacy C scanner against the pure-Ruby scanner on a corpus.
#
# The C scanner is loaded in a subprocess (it segfaults on some inputs and we
# do not want that to kill the test run). Both sides serialize with
# to_html(:preserve => true) and we assert the bytes match exactly.
require 'open3'
require 'json'

module DifferentialHelper
  REPO = File.expand_path('..', __dir__)

  # Files the corpus is drawn from: the shipped fixtures plus anything the
  # operator drops into test/corpus/ (real customer files, gitignored).
  def self.corpus_paths
    Dir[File.join(REPO, 'test/files/*')] +
      Dir[File.join(REPO, 'test/corpus/**/*')].select { |f| File.file?(f) }
  end

  # Runs the OLD C scanner out-of-process. Returns the serialized document, or
  # :crashed if the child died on a signal, or [:error, msg] on a Ruby exception.
  def self.legacy_parse(path, xml:)
    script = <<~RUBY
      $LOAD_PATH.unshift(#{File.join(REPO, 'lib').inspect})
      $LOAD_PATH.unshift(#{File.join(REPO, 'ext/hpricot_scan').inspect})
      require 'hpricot'
      src = File.binread(#{path.inspect})
      doc = Hpricot.scan(src, #{xml ? '{ :xml => true }' : '{}'})
      $stdout.binmode
      $stdout.write(doc.to_html(:preserve => true))
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, '-e', script)
    return :crashed unless status.exited?
    return [:error, err.lines.first.to_s.strip] unless status.success?

    out
  end

  # Runs the NEW Ruby scanner in-process.
  def self.current_parse(path, xml:)
    src = File.binread(path)
    doc = Hpricot.scan(src, xml ? { :xml => true } : {})
    doc.to_html(:preserve => true)
  rescue StandardError => e
    [:error, "#{e.class}: #{e.message}"]
  end
end
```

Then create `test/test_differential.rb`:

```ruby
# frozen_string_literal: true

require 'test/unit'
require_relative 'differential_helper'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'hpricot'

class TestDifferential < Test::Unit::TestCase
  DifferentialHelper.corpus_paths.each do |path|
    name = File.basename(path).gsub(/\W/, '_')

    define_method("test_xml_mode_#{name}") do
      assert_matches_legacy(path, xml: true)
    end

    define_method("test_html_mode_#{name}") do
      assert_matches_legacy(path, xml: false)
    end
  end

  # An empty corpus must fail loudly rather than pass vacuously.
  def test_corpus_is_not_empty
    assert_operator DifferentialHelper.corpus_paths.length, :>, 0,
                    'no corpus files found; test/files/ should not be empty'
  end

  private

  def assert_matches_legacy(path, xml:)
    legacy = DifferentialHelper.legacy_parse(path, xml: xml)

    # The old scanner crashing is a known defect, not a reason to fail the
    # port. Skip those inputs; Task 11 asserts the new one does NOT crash.
    omit("legacy scanner crashed on #{path}") if legacy == :crashed
    omit("legacy scanner raised on #{path}: #{legacy[1]}") if legacy.is_a?(Array)

    current = DifferentialHelper.current_parse(path, xml: xml)
    flunk("new scanner raised on #{path}: #{current[1]}") if current.is_a?(Array)

    assert_equal legacy.bytesize, current.bytesize,
                 "byte length differs for #{path} (xml=#{xml})"
    assert_equal legacy, current,
                 "output differs for #{path} (xml=#{xml})"
  end
end
```

- [ ] **Step 2: Run it against the C scanner as both sides (sanity check)**

At this point `Hpricot.scan` is still the C version on both sides, so every test must pass. This proves the harness itself is sound.

```bash
ruby -Ilib -Iext/hpricot_scan -Itest test/test_differential.rb 2>&1 | tail -5
```

Expected: all tests pass or omit; **0 failures**. If any fail, the harness is wrong — fix it before proceeding.

- [ ] **Step 3: Gitignore the private corpus**

Append to `.gitignore`:

```
/test/corpus/*
!/test/corpus/.gitkeep
```

- [ ] **Step 4: Commit**

```bash
git add test/differential_helper.rb test/test_differential.rb test/corpus/.gitkeep .gitignore
git commit -m "Add differential harness comparing C and Ruby scanners

Runs the legacy C scanner out-of-process so its known segfaults cannot
kill the test run, and asserts byte-identical to_html(:preserve) output
against the new scanner. Drop real files into test/corpus/ to widen
coverage; that directory is gitignored."
```

---

## Task 3: Node classes

**Files:**
- Create: `lib/hpricot/nodes.rb`
- Create: `test/test_nodes.rb`

- [ ] **Step 1: Write the failing test**

Create `test/test_nodes.rb`:

```ruby
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
    b.raw_string = '</div >'
    assert_equal '</div >', b.raw_string
    b.clear_raw
    assert_nil b.raw_string
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
ruby -Ilib -Itest test/test_nodes.rb
```

Expected: FAIL — `cannot load such file -- hpricot/nodes`.

- [ ] **Step 3: Write the implementation**

Create `lib/hpricot/nodes.rb`:

```ruby
# frozen_string_literal: true

# Plain-Ruby replacements for the Struct-like classes the C extension built.
#
# Slot layout is preserved from ext/hpricot_scan/hpricot_scan.rl:853-861 so that
# traverse.rb, elements.rb and builder.rb work unchanged:
#
#   basic (2): name, parent
#   attr  (3): name, parent, raw_attributes
#   elem  (8): name, parent, raw_attributes, etag, raw_string, allowed,
#              tagno, children
module Hpricot
  # Shared by Text, Comment, CData.
  class BasicNode
    attr_accessor :name, :parent
  end

  # Shared by DocType, ProcIns, XMLDecl, BogusETag.
  class AttrNode
    attr_accessor :name, :parent, :raw_attributes
  end

  # Shared by Doc and Elem.
  class ElemNode
    attr_accessor :name, :parent, :raw_attributes, :etag, :raw_string,
                  :allowed, :tagno, :children
  end

  class Text < BasicNode
    alias content name
    alias content= name=
    alias raw_string name

    def clear_raw
      self.name = nil
    end
  end

  class Comment < BasicNode
    alias content name
    alias content= name=
  end

  class CData < BasicNode
    alias content name
    alias content= name=
  end

  class DocType < AttrNode
    alias raw_string name

    def clear_raw
      self.name = nil
    end

    def target       = (raw_attributes || {})[:target]
    def target=(v)   = ((self.raw_attributes ||= {})[:target] = v)
    def public_id    = (raw_attributes || {})[:public_id]
    def public_id=(v) = ((self.raw_attributes ||= {})[:public_id] = v)
    def system_id    = (raw_attributes || {})[:system_id]
    def system_id=(v) = ((self.raw_attributes ||= {})[:system_id] = v)
  end

  class XMLDecl < AttrNode
    alias raw_string name

    def clear_raw
      self.name = nil
    end

    def version        = (raw_attributes || {})[:version]
    def version=(v)    = ((self.raw_attributes ||= {})[:version] = v)
    def encoding       = (raw_attributes || {})[:encoding]
    def encoding=(v)   = ((self.raw_attributes ||= {})[:encoding] = v)
    def standalone     = (raw_attributes || {})[:standalone]
    def standalone=(v) = ((self.raw_attributes ||= {})[:standalone] = v)
  end

  class ProcIns < AttrNode
    alias target name
    alias target= name=
    alias content raw_attributes
    alias content= raw_attributes=
  end

  class BogusETag < AttrNode
    alias raw_string raw_attributes

    def clear_raw
      self.raw_attributes = nil
    end
  end

  class Elem < ElemNode
    def clear_raw
      self.raw_string = nil
    end
  end

  class Doc < ElemNode
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
ruby -Ilib -Itest test/test_nodes.rb
```

Expected: `6 tests, ... 0 failures, 0 errors`.

- [ ] **Step 5: Commit**

```bash
git add lib/hpricot/nodes.rb test/test_nodes.rb
git commit -m "Add pure-Ruby node classes

Reproduces the slot layout and accessor aliases the C extension's
Struct-like classes provided, so traverse.rb and elements.rb are
unaffected."
```

---

## Task 4: Tokenizer — leaf constructs

Text, comments, CDATA, processing instructions, doctype, XML declaration. Tags come in Task 5.

**Files:**
- Create: `lib/hpricot/scanner.rb`
- Create: `test/test_scanner.rb`

- [ ] **Step 1: Write the failing test**

Create `test/test_scanner.rb`:

```ruby
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
```

- [ ] **Step 2: Run it to verify it fails**

```bash
ruby -Ilib -Itest test/test_scanner.rb
```

Expected: FAIL — `cannot load such file -- hpricot/scanner`.

- [ ] **Step 3: Write the implementation**

Create `lib/hpricot/scanner.rb`:

```ruby
# frozen_string_literal: true

require 'strscan'

module Hpricot
  # Token carrying its exact source bytes.
  #
  # `raw` is the fidelity mechanism: it is the verbatim slice of the input this
  # token came from, and the tree builder stores it so serialization can emit
  # the original bytes rather than re-encoding. Never decode into `raw`.
  Token = Struct.new(:kind, :name, :attrs, :content, :raw, :closed)

  # Liberal tokenizer for HTML/XML, modelled on ext/hpricot_scan/hpricot_scan.rl.
  #
  # Rules of the port:
  #   * Never raise on malformed input. Anything unrecognised becomes text.
  #   * Every byte of the input appears in exactly one token's `raw`.
  #   * Attribute values are stored undecoded.
  class Scanner
    def initialize(source, xml: false, fixup_tags: false, xhtml_strict: false)
      @src = source
      @xml = xml
      @fixup_tags = fixup_tags
      @xhtml_strict = xhtml_strict
      @ss = StringScanner.new(source)
    end

    def tokens
      @tokens ||= begin
        out = []
        out << next_token until @ss.eos?
        out
      end
    end

    private

    def next_token
      start = @ss.pos

      if @ss.scan(/<!--/)      then comment(start)
      elsif @ss.scan(/<!\[CDATA\[/) then cdata(start)
      elsif @ss.scan(/<\?/)    then procins(start)
      elsif @ss.scan(/<!/)     then doctype(start)
      elsif (m = @ss.scan(%r{</([^\s>]*)\s*>?}))
        Token.new(:etag, @ss[1], nil, nil, m, nil)
      elsif @ss.check(/<[A-Za-z_:]/)
        tag(start)
      else
        text(start)
      end
    end

    # Scans to `terminator`, or to EOF if it never appears (liberality).
    def upto(terminator)
      body = @ss.scan_until(terminator)
      return [@ss.scan(/.*/m), false] if body.nil?

      [body[0...-terminator.source.length] || body, true]
    end

    def comment(start)
      inner = @ss.scan_until(/-->/)
      if inner.nil?
        inner = @ss.scan(/.*/m).to_s
        content = inner
      else
        content = inner[0...-3]
      end
      Token.new(:comment, nil, nil, content, span(start), nil)
    end

    def cdata(start)
      inner = @ss.scan_until(/\]\]>/)
      if inner.nil?
        inner = @ss.scan(/.*/m).to_s
        content = inner
      else
        content = inner[0...-3]
      end
      Token.new(:cdata, nil, nil, content, span(start), nil)
    end

    def procins(start)
      inner = @ss.scan_until(/\?>/)
      inner = @ss.scan(/.*/m).to_s if inner.nil?
      body = inner.sub(/\?>\z/, '')
      target = body[/\A[^\s]+/].to_s
      rest = body[target.length..].to_s.strip

      if target == 'xml'
        Token.new(:xmldecl, target, parse_attrs(rest), rest, span(start), nil)
      else
        Token.new(:procins, target, nil, rest, span(start), nil)
      end
    end

    def doctype(start)
      @ss.scan_until(/>/) || @ss.scan(/.*/m)
      raw = span(start)
      Token.new(:doctype, nil, parse_doctype(raw), nil, raw, nil)
    end

    def text(start)
      # Consume one '<' that did not start a recognised construct, then run to
      # the next '<'. This is what makes stray '<' render as text.
      @ss.getch if @ss.check(/</)
      @ss.scan(/[^<]*/m)
      Token.new(:text, nil, nil, nil, span(start), nil)
    end

    def span(start)
      @src.byteslice(start, @ss.pos - start)
    end

    ATTR_RE = /\s*([^\s=\/><]+)(?:\s*=\s*("[^"]*"|'[^']*'|[^\s>]*))?/

    def parse_attrs(str)
      attrs = {}
      s = StringScanner.new(str.to_s)
      while s.scan(ATTR_RE)
        key = s[1]
        val = s[2]
        val = val[1...-1] if val && (val.start_with?('"') || val.start_with?("'"))
        key = key.downcase unless @xml
        attrs[key] = val
      end
      attrs
    end

    def parse_doctype(raw)
      attrs = {}
      if (m = raw.match(/\A<!DOCTYPE\s+([^\s>]+)/i))
        attrs[:target] = m[1]
      end
      attrs[:public_id] = Regexp.last_match(1) if raw =~ /PUBLIC\s+"([^"]*)"/i
      attrs[:system_id] = Regexp.last_match(1) if raw =~ /(?:SYSTEM|"\s+)"([^"]*)"\s*>?\z/i
      attrs
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
ruby -Ilib -Itest test/test_scanner.rb
```

Expected: `8 tests, ... 0 failures, 0 errors`. Fix the implementation until green — do not edit the test to match buggy output.

- [ ] **Step 5: Commit**

```bash
git add lib/hpricot/scanner.rb test/test_scanner.rb
git commit -m "Add tokenizer for text, comments, CDATA, PIs and doctype

Each token retains its exact source byte span, which is how byte-identical
round-tripping is achieved: nothing is decoded during scanning."
```

---

## Task 5: Tokenizer — tags and attributes

**Files:**
- Modify: `lib/hpricot/scanner.rb`
- Modify: `test/test_scanner.rb`

- [ ] **Step 1: Write the failing test**

Append to `test/test_scanner.rb`, inside `class TestScanner`:

```ruby
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
```

- [ ] **Step 2: Run it to verify it fails**

```bash
ruby -Ilib -Itest test/test_scanner.rb -n /tag|attribute|reassembles/
```

Expected: FAIL — `tag` is not implemented (`NoMethodError` or wrong token kinds).

- [ ] **Step 3: Write the implementation**

In `lib/hpricot/scanner.rb`, add the `tag` method to the private section (place it after `text`):

```ruby
    def tag(start)
      @ss.getch                       # consume '<'
      name = @ss.scan(/[^\s\/>]+/).to_s
      attrs = {}

      loop do
        @ss.scan(/\s+/)
        break if @ss.eos? || @ss.check(/\/?>/)

        key = @ss.scan(%r{[^\s=/><]+})
        break if key.nil?

        val = nil
        if @ss.scan(/\s*=\s*/)
          val = if (q = @ss.scan(/"[^"]*"|'[^']*'/))
                  q[1...-1]
                else
                  @ss.scan(%r{[^\s>]*})
                end
        end
        key = key.downcase unless @xml
        attrs[key] = val
      end

      empty = !@ss.scan(%r{\s*/>}).nil?
      @ss.scan(/\s*>/) unless empty

      Token.new(empty ? :emptytag : :stag,
                @xml ? name : name.downcase,
                attrs, nil, span(start), empty)
    end
```

- [ ] **Step 4: Run the full scanner suite**

```bash
ruby -Ilib -Itest test/test_scanner.rb
```

Expected: `15 tests, ... 0 failures, 0 errors`.

- [ ] **Step 5: Commit**

```bash
git add lib/hpricot/scanner.rb test/test_scanner.rb
git commit -m "Add tag and attribute tokenizing

Attribute values are stored undecoded so numeric character references and
&quot; survive a parse/serialize round trip byte-identically."
```

---

## Task 6: Tree builder — XML mode

XML mode has no implicit closing, so it is the simple case. HTML follows in Task 7.

**Files:**
- Create: `lib/hpricot/tree_builder.rb`
- Create: `test/test_tree_builder.rb`

- [ ] **Step 1: Write the failing test**

Create `test/test_tree_builder.rb`:

```ruby
# frozen_string_literal: true

require 'test/unit'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'hpricot'

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

  def test_round_trips_byte_identically
    src = %(<?xml version="1.0"?>\n<r a="1">\n  <s>x&#8230;&quot;y</s>\n</r>\n)
    assert_equal src, build(src, xml: true).to_html(:preserve => true)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
ruby -Ilib -Iext/hpricot_scan -Itest test/test_tree_builder.rb
```

Expected: FAIL — `uninitialized constant Hpricot::TreeBuilder`.

- [ ] **Step 3: Write the implementation**

Create `lib/hpricot/tree_builder.rb`:

```ruby
# frozen_string_literal: true

require 'hpricot/nodes'

module Hpricot
  # Turns a Scanner token stream into a Hpricot::Doc tree.
  #
  # XML mode is a straight push/pop of a stack. HTML mode additionally applies
  # implicit closing driven by ElementContent (see #close_implied), matching
  # ext/hpricot_scan/hpricot_scan.rl:316-400.
  class TreeBuilder
    def initialize(tokens, xml: false, fixup_tags: false, xhtml_strict: false)
      @tokens = tokens
      @xml = xml
      @fixup_tags = fixup_tags
      @xhtml_strict = xhtml_strict
    end

    def document
      @document ||= build
    end

    private

    def build
      doc = Doc.new
      doc.children = []
      @stack = [doc]

      @tokens.each { |tok| consume(tok) }

      doc
    end

    def focus = @stack.last

    def add(node)
      node.parent = focus
      (focus.children ||= []) << node
      node
    end

    def consume(tok)
      case tok.kind
      when :text      then add(text_node(tok))
      when :comment   then add(simple(Comment, tok.content))
      when :cdata     then add(simple(CData, tok.content))
      when :procins   then add(procins(tok))
      when :xmldecl   then add(xmldecl(tok))
      when :doctype   then add(doctype(tok))
      when :stag      then open_element(tok)
      when :emptytag  then add(element(tok))
      when :etag      then close_element(tok)
      end
    end

    def text_node(tok)
      t = Text.new
      t.content = tok.raw
      t
    end

    def simple(klass, content)
      n = klass.new
      n.content = content
      n
    end

    def procins(tok)
      p = ProcIns.new
      p.target = tok.name
      p.content = tok.content
      p
    end

    def xmldecl(tok)
      x = XMLDecl.new
      x.raw_attributes = {
        version: tok.attrs['version'],
        encoding: tok.attrs['encoding'],
        standalone: tok.attrs['standalone']
      }
      x.name = tok.raw
      x
    end

    def doctype(tok)
      d = DocType.new
      d.raw_attributes = tok.attrs
      d.name = tok.raw
      d
    end

    def element(tok)
      e = Elem.new
      e.name = tok.name
      e.raw_attributes = tok.attrs
      e.raw_string = tok.raw
      e.tagno = tok.name.hash
      e.allowed = ElementContent[tok.name] unless @xml
      e
    end

    def open_element(tok)
      close_implied(tok.name) unless @xml
      e = add(element(tok))
      e.children = []
      @stack.push(e)
    end

    def close_element(tok)
      idx = @stack.rindex { |n| n.is_a?(Elem) && n.name == tok.name }

      if idx.nil?
        # No matching open tag: hpricot keeps the bytes as a BogusETag rather
        # than discarding them, which is required for byte-identical output.
        b = BogusETag.new
        b.name = tok.name
        b.raw_string = tok.raw
        add(b)
        return
      end

      @stack[idx].etag = tok.raw
      @stack.pop(@stack.length - idx)
    end

    # HTML implicit closing: <li> closes an open <li>, <td> closes <td>, and so
    # on. ElementContent[open_tag] is a Hash keyed by tag_name.hash whose value
    # says whether the new tag may appear inside the open one.
    def close_implied(new_name)
      key = new_name.hash
      while (open = focus) && open.is_a?(Elem)
        allowed = open.allowed
        break if allowed.nil?
        break if allowed[key]

        @stack.pop
      end
    end
  end
end
```

- [ ] **Step 4: Wire the constant so the test can load it**

Add to `lib/hpricot.rb`, after the existing `require 'hpricot/tag'` line:

```ruby
require 'hpricot/scanner'
require 'hpricot/tree_builder'
```

- [ ] **Step 5: Run the test**

```bash
ruby -Ilib -Iext/hpricot_scan -Itest test/test_tree_builder.rb
```

Expected: `6 tests, ... 0 failures, 0 errors`.

- [ ] **Step 6: Commit**

```bash
git add lib/hpricot/tree_builder.rb test/test_tree_builder.rb lib/hpricot.rb
git commit -m "Add tree builder for XML mode

Builds the Doc/Elem graph from the token stream, keeping raw spans on
each node. Unmatched end tags become BogusETag so their bytes survive."
```

---

## Task 7: Tree builder — HTML implicit closing

**Files:**
- Modify: `lib/hpricot/tree_builder.rb`
- Modify: `test/test_tree_builder.rb`

- [ ] **Step 1: Write the failing test**

Append to `test/test_tree_builder.rb`, inside `class TestTreeBuilder`:

```ruby
  def test_li_implicitly_closes_li
    doc = build('<ul><li>a<li>b</ul>')
    ul = doc.children[0]
    assert_equal 2, ul.children.count { |c| c.is_a?(Hpricot::Elem) && c.name == 'li' }
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
```

- [ ] **Step 2: Run it to verify it fails**

```bash
ruby -Ilib -Iext/hpricot_scan -Itest test/test_tree_builder.rb -n /implicitly|downcases/
```

Expected: FAIL — the `li`/`p` cases nest instead of closing.

- [ ] **Step 3: Fix `close_implied`**

The Task 6 version stops at the first element. Replace `close_implied` in `lib/hpricot/tree_builder.rb` with:

```ruby
    # HTML implicit closing. ElementContent[tag] is a Hash keyed by
    # tag_name.hash; a missing key means the new tag is not permitted inside
    # the open one, so the open one is closed first.
    #
    # :deny entries close unconditionally, :allow entries never close.
    # See ext/hpricot_scan/hpricot_scan.rl:316-360.
    def close_implied(new_name)
      key = new_name.hash

      while focus.is_a?(Elem)
        allowed = focus.allowed
        break if allowed.nil?

        case allowed[key]
        when :deny  then @stack.pop
        when nil    then @stack.pop
        else             break            # true or :allow — may nest
        end
      end
    end
```

- [ ] **Step 4: Run the tests**

```bash
ruby -Ilib -Iext/hpricot_scan -Itest test/test_tree_builder.rb
```

Expected: `10 tests, ... 0 failures, 0 errors`.

- [ ] **Step 5: Commit**

```bash
git add lib/hpricot/tree_builder.rb test/test_tree_builder.rb
git commit -m "Add HTML implicit tag closing

Drives implicit closes from ElementContent so <li>a<li>b produces two
siblings rather than nested elements, matching the C scanner."
```

---

## Task 8: Encoding handling

The C scanner tags every node with `Encoding.default_external` regardless of the input's own encoding (`hpricot_scan.rl:495`), producing `valid_encoding? == false` strings for Latin-1 input. Do not reproduce that bug.

**Files:**
- Modify: `lib/hpricot/scanner.rb`
- Create: `test/test_encoding.rb`

- [ ] **Step 1: Write the failing test**

Create `test/test_encoding.rb`:

```ruby
# frozen_string_literal: true

require 'test/unit'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'hpricot'

class TestEncoding < Test::Unit::TestCase
  def test_preserves_input_encoding
    src = '<p>café</p>'.encode('ISO-8859-1')
    doc = Hpricot.scan(src, {})
    text = doc.children[0].children[0].content
    assert_equal Encoding::ISO_8859_1, text.encoding
    assert text.valid_encoding?, 'text should be valid in its declared encoding'
  end

  def test_utf8_input_stays_utf8
    doc = Hpricot.scan('<p>café</p>', {})
    text = doc.children[0].children[0].content
    assert_equal Encoding::UTF_8, text.encoding
    assert text.valid_encoding?
  end

  # An unknown encoding in the XML declaration must not raise. The C scanner
  # raised EncodingError here (hpricot_scan.rl:146-153, no -1 guard).
  def test_unknown_declared_encoding_does_not_raise
    assert_nothing_raised do
      Hpricot.scan('<r>hi</r><?xml version="1.0" encoding="pwn"?>', {})
    end
  end

  def test_binary_input_does_not_raise
    src = "<p>caf\xE9</p>".dup.force_encoding('ASCII-8BIT')
    assert_nothing_raised { Hpricot.scan(src, {}) }
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
ruby -Ilib -Itest test/test_encoding.rb
```

Expected: FAIL — `Hpricot.scan` is still the C version (or undefined once Task 9 lands). Run it again after Task 9 if it errors on load.

- [ ] **Step 3: Implement encoding handling**

In `lib/hpricot/scanner.rb`, replace `initialize` with:

```ruby
    def initialize(source, xml: false, fixup_tags: false, xhtml_strict: false)
      @src = source
      @xml = xml
      @fixup_tags = fixup_tags
      @xhtml_strict = xhtml_strict
      @ss = StringScanner.new(source)
    end

    # Encoding named by an <?xml encoding=?> declaration, if it names one Ruby
    # knows. Unknown names are ignored rather than raising.
    def declared_encoding
      m = @src.match(/<\?xml[^>]*encoding\s*=\s*["']([^"']+)["']/i)
      return nil unless m

      Encoding.find(m[1])
    rescue ArgumentError
      nil
    end
```

Byte spans produced by `String#byteslice` already inherit the source string's encoding, so no re-tagging is needed — the fix is simply *not* forcing `default_external`. Add this to `span`:

```ruby
    def span(start)
      @src.byteslice(start, @ss.pos - start)
    end
```

(unchanged — documenting that it inherits `@src`'s encoding is the point).

- [ ] **Step 4: Run the test after Task 9 wires `Hpricot.scan`**

Defer verification to Task 9 Step 5. Note it in the commit.

- [ ] **Step 5: Commit**

```bash
git add lib/hpricot/scanner.rb test/test_encoding.rb
git commit -m "Preserve input encoding instead of forcing default_external

The C scanner tagged every node Encoding.default_external regardless of
the source encoding, producing strings that fail valid_encoding? for
Latin-1 input. Byte spans now inherit the source string's encoding, and
an unknown declared encoding is ignored rather than raising."
```

---

## Task 9: Replace `Hpricot.scan`

**Files:**
- Modify: `lib/hpricot.rb`
- Create: `lib/hpricot/xs.rb`

- [ ] **Step 1: Write the Ruby replacement for fast_xs**

Create `lib/hpricot/xs.rb`:

```ruby
# frozen_string_literal: true

# Replaces the fast_xs C extension. Escapes a String for XML text content.
#
# The C version also mapped a handful of CP-1252 bytes; that table was buggy
# (bytes 129, 141, 143, 144, 157 emitted "*" instead of the documented numeric
# reference), so this drops the special-casing and escapes only what XML
# requires plus non-ASCII as numeric references.
class String
  XS_ESCAPES = { '&' => '&amp;', '<' => '&lt;', '>' => '&gt;',
                 '"' => '&quot;', "'" => '&apos;' }.freeze

  def fast_xs
    each_char.map do |c|
      if (esc = XS_ESCAPES[c])
        esc
      elsif c.ord < 128
        c
      else
        "&##{c.ord};"
      end
    end.join
  end
end
```

- [ ] **Step 2: Rewire the requires and define `Hpricot.scan`**

In `lib/hpricot.rb`, replace the block that requires the extensions (currently lines 15-26, the `require 'hpricot_scan'` / `require 'fast_xs'` region plus the dead `require 'encoding/character/utf-8'` rescue) with:

```ruby
require 'hpricot/xs'
require 'hpricot/nodes'
require 'hpricot/scanner'
require 'hpricot/tree_builder'
require 'hpricot/tags'
require 'hpricot/htmlinfo'
require 'hpricot/modules'
require 'hpricot/tag'
require 'hpricot/traverse'
require 'hpricot/inspect'
require 'hpricot/parse'
require 'hpricot/builder'

module Hpricot
  class ParseError < StandardError; end

  class << self
    attr_accessor :buffer_size
  end

  # Parses `input` (a String or an object responding to #read) into a Doc.
  #
  # Replaces the C singleton method of the same name. The block form of the
  # old C version is not supported: it segfaulted on any tag with an attribute
  # and had no callers.
  def self.scan(input, opts = {})
    source = input.respond_to?(:read) ? input.read : input.to_s
    kw = { xml: !!opts[:xml],
           fixup_tags: !!opts[:fixup_tags],
           xhtml_strict: !!opts[:xhtml_strict] }
    TreeBuilder.new(Scanner.new(source, **kw).tokens, **kw).document
  end
end
```

Keep `require 'hpricot/blankslate'` only if `builder.rb` still needs it — Task 12 removes it.

- [ ] **Step 3: Verify the extension is no longer loaded**

```bash
cd /Users/edouard/code/github/hpricot
ruby -Ilib -e 'require "hpricot"; puts $LOADED_FEATURES.grep(/hpricot_scan|fast_xs/).empty? ? "no native ext loaded" : "STILL LOADING NATIVE EXT"'
```

Expected: `no native ext loaded`.

- [ ] **Step 4: Run the encoding tests deferred from Task 8**

```bash
ruby -Ilib -Itest test/test_encoding.rb
```

Expected: `4 tests, ... 0 failures, 0 errors`.

- [ ] **Step 5: Run the differential harness — the real gate**

```bash
ruby -Ilib -Itest test/test_differential.rb 2>&1 | tail -20
```

This compares the C scanner (subprocess, built from the still-present `ext/`) against your Ruby one on every fixture. Expect failures on the first run. **Fix the Ruby scanner until this is green** — each failure names the file and mode. This is the bulk of the work in this plan; budget for it.

- [ ] **Step 6: Commit**

```bash
git add lib/hpricot.rb lib/hpricot/xs.rb
git commit -m "Replace the C scanner with the pure-Ruby implementation

Hpricot.scan is now Ruby. The block form of the old C method is dropped:
it dereferenced a NULL state pointer on any tag with an attribute and
had no callers."
```

---

## Task 10: Full suite parity

**Files:**
- Modify: `lib/hpricot/scanner.rb`, `lib/hpricot/tree_builder.rb` as needed

- [ ] **Step 1: Run the whole existing suite**

```bash
cd /Users/edouard/code/github/hpricot
for f in test/test_*.rb; do echo "== $f"; ruby -Ilib -Itest "$f" 2>&1 | tail -2; done
```

- [ ] **Step 2: Fix until green**

Target: **0 failures, 0 errors** across `test_alter.rb`, `test_builder.rb`, `test_parser.rb`, `test_paths.rb`, `test_preserved.rb`, `test_xml.rb`. `test_preserved.rb` (5,950 assertions on round-trip fidelity) is the most valuable signal — it is effectively a second differential harness.

Do not weaken a test to make it pass. If a test encodes C-specific behaviour that is genuinely wrong (e.g. `default_external` tagging), change it and say so in the commit body.

- [ ] **Step 3: Prove determinism**

```bash
for i in $(seq 1 20); do
  ruby -Ilib -Itest test/test_parser.rb 2>&1 | grep -oE '[0-9]+ failures, [0-9]+ errors'
done | sort | uniq -c
```

Expected: exactly one line, `20  0 failures, 0 errors`. Any variation means non-determinism survived — investigate before continuing.

- [ ] **Step 4: Commit**

```bash
git add -A lib test
git commit -m "Reach parity with the C scanner on the full test suite

20 consecutive runs produce identical results, replacing the C scanner's
run-to-run variation caused by an uninitialized read."
```

---

## Task 11: Robustness — the inputs that crashed the C version

**Files:**
- Create: `test/test_robustness.rb`

- [ ] **Step 1: Write the test**

Create `test/test_robustness.rb`:

```ruby
# frozen_string_literal: true

require 'test/unit'
require 'stringio'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'hpricot'

# Inputs that segfaulted, leaked or hung the C extension. All must now be
# ordinary Ruby behaviour.
class TestRobustness < Test::Unit::TestCase
  def test_io_at_buffer_boundary
    # C: segfault at exactly 16384 bytes (RSTRING_LEN on a nil read).
    [16_383, 16_384, 16_385, 32_768].each do |n|
      assert_nothing_raised("failed at #{n} bytes") do
        Hpricot(StringIO.new('x' * n))
      end
    end
  end

  def test_reader_returning_nil
    reader = Class.new { def read(_n = nil) = nil }.new
    assert_nothing_raised { Hpricot(reader) }
  end

  def test_unknown_declared_encoding
    # C: EncodingError plus a permanent ~1.4KB leak per call.
    assert_nothing_raised do
      Hpricot::XML('<r><s>hi</s></r><?xml version="1.0" encoding="pwn"?>')
    end
  end

  def test_deeply_nested_input_does_not_blow_the_stack
    src = ('<a>' * 5_000) + ('</a>' * 5_000)
    assert_nothing_raised { Hpricot::XML(src) }
  end

  def test_malformed_fragments_never_raise
    [
      '<', '<<<', '<a', '<a b', '<a b=', '<a b="', '</', '</>', '<!--',
      '<![CDATA[', '<?', '<!', '<a></b></a>', '&#99999999999;', "\x00<a>"
    ].each do |src|
      assert_nothing_raised("raised on #{src.inspect}") { Hpricot::XML(src.dup) }
    end
  end

  def test_no_unbounded_growth_on_repeated_failures
    src = '<r><s>hi</s></r><?xml version="1.0" encoding="pwn"?>'
    GC.start
    before = GC.stat(:total_allocated_objects)
    2_000.times { Hpricot::XML(src.dup) }
    GC.start
    live = ObjectSpace.count_objects[:TOTAL] - ObjectSpace.count_objects[:FREE]
    assert_operator live, :<, before, 'object count should not grow unboundedly'
  end
end
```

- [ ] **Step 2: Run it**

```bash
ruby -Ilib -Itest test/test_robustness.rb
```

Expected: `6 tests, ... 0 failures, 0 errors`. If `test_deeply_nested_input_does_not_blow_the_stack` fails with `SystemStackError`, the tree builder is recursing — it should not be (it is a loop over a flat token list), so investigate rather than raising the stack limit.

- [ ] **Step 3: Commit**

```bash
git add test/test_robustness.rb
git commit -m "Add regression tests for inputs that crashed the C scanner

Covers the 16KB IO boundary segfault, readers returning nil, the unknown
declared-encoding leak, deep nesting and assorted malformed fragments."
```

---

## Task 12: Remove BlankSlate

`lib/hpricot/blankslate.rb` installs an `Object.method_added` hook that fires for every `def` anywhere in the host process, leaks `method_added` as a public method on every class, and raises `SystemStackError` if the file is loaded twice. Its `hide` guard has been dead since Ruby 1.9 (`instance_methods` returns Symbols, compared against Strings), so `BlankSlate` hides nothing.

**Files:**
- Modify: `lib/hpricot/builder.rb:192`
- Delete: `lib/hpricot/blankslate.rb`
- Create: `test/test_css_proxy.rb`

- [ ] **Step 1: Write the failing test**

Create `test/test_css_proxy.rb`:

```ruby
# frozen_string_literal: true

require 'test/unit'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'hpricot'

class TestCssProxy < Test::Unit::TestCase
  # BlankSlate never hid anything, so CSS class names colliding with Object
  # methods silently did the wrong thing.
  def test_class_names_colliding_with_object_methods
    doc = Hpricot.build { div.display { text 'x' } }
    assert_match(/class="display"/, doc.to_html)
  end

  def test_requiring_hpricot_does_not_patch_object
    refute String.respond_to?(:method_added),
           'method_added must not be public on every class'
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
ruby -Ilib -Itest test/test_css_proxy.rb
```

Expected: FAIL on both — `display` is swallowed by `Object#display`, and `method_added` is public.

- [ ] **Step 3: Switch CssProxy to BasicObject**

In `lib/hpricot/builder.rb:192`, change:

```ruby
  class CssProxy < BlankSlate
```

to:

```ruby
  class CssProxy < BasicObject
```

Remove the `require 'hpricot/blankslate'` line from `lib/hpricot/builder.rb` and from `lib/hpricot.rb` if present, then:

```bash
git rm lib/hpricot/blankslate.rb
```

- [ ] **Step 4: Run the tests**

```bash
ruby -Ilib -Itest test/test_css_proxy.rb && ruby -Ilib -Itest test/test_builder.rb
```

Expected: both green.

- [ ] **Step 5: Commit**

```bash
git add -A lib test/test_css_proxy.rb
git commit -m "Replace BlankSlate with BasicObject

BlankSlate hid nothing (its guard compared Symbols to Strings, dead since
Ruby 1.9), installed a process-wide Object.method_added hook that fired on
every def in the host application, and raised SystemStackError if loaded
twice."
```

---

## Task 13: Delete the extensions

Only after Tasks 9-12 are green.

**Files:**
- Delete: `ext/`, `setup.rb`, `.travis.yml`
- Create: `docs/grammar/hpricot_scan.rl`, `docs/grammar/hpricot_common.rl`
- Modify: `hpricot.gemspec`, `Rakefile`, `.gitignore`

- [ ] **Step 1: Preserve the grammar as documentation**

```bash
cd /Users/edouard/code/github/hpricot
mkdir -p docs/grammar
git mv ext/hpricot_scan/hpricot_scan.rl docs/grammar/hpricot_scan.rl
git mv ext/hpricot_scan/hpricot_common.rl docs/grammar/hpricot_common.rl
```

- [ ] **Step 2: Delete the rest**

```bash
git rm -r ext
git rm setup.rb .travis.yml
rm -rf ext
```

- [ ] **Step 3: Rewrite the gemspec**

Replace `hpricot.gemspec` entirely:

```ruby
Gem::Specification.new do |s|
  s.name = 'webtranslateit-hpricot'
  s.version = '1.0.0'

  s.authors = ['why the lucky stiff', 'WebTranslateIt']
  s.email = 'support@webtranslateit.com'
  s.description = 'A swift, liberal HTML/XML parser that preserves the source bytes of what it parses.'
  s.summary = 'A liberal HTML/XML parser with byte-identical round-tripping'
  s.homepage = 'https://github.com/webtranslateit/hpricot'
  s.license = 'MIT'

  s.required_ruby_version = '>= 3.2'
  s.files = `git ls-files -z`.split("\x0").reject { |f| f.start_with?('docs/', 'test/corpus/') }
  s.require_paths = ['lib']
  s.extra_rdoc_files = ['README.md', 'CHANGELOG', 'COPYING']

  s.metadata = {
    'source_code_uri' => 'https://github.com/webtranslateit/hpricot',
    'bug_tracker_uri' => 'https://github.com/webtranslateit/hpricot/issues',
    'changelog_uri' => 'https://github.com/webtranslateit/hpricot/blob/master/CHANGELOG',
    'rubygems_mfa_required' => 'true'
  }

  s.add_development_dependency 'rake', '~> 13.0'
  s.add_development_dependency 'test-unit', '~> 3.7'
end
```

Note there is no `s.extensions` line — that is the point of this task.

- [ ] **Step 4: Rewrite the Rakefile**

Replace `Rakefile` entirely:

```ruby
require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs = %w[lib test]
  t.test_files = FileList['test/test_*.rb']
  t.verbose = true
end

desc 'Run the suite 20 times to prove determinism'
task :determinism do
  results = 20.times.map do
    `ruby -Ilib -Itest test/test_parser.rb 2>&1`[/\d+ failures, \d+ errors/]
  end.uniq
  abort "non-deterministic: #{results.inspect}" if results.length != 1
  puts "deterministic across 20 runs: #{results.first}"
end

task default: :test
```

- [ ] **Step 5: Tidy .gitignore**

Replace `.gitignore` with:

```
*.gem
*.bundle
*.so
*.o
*.dSYM/
/pkg
/Gemfile.lock
/test/corpus/*
!/test/corpus/.gitkeep
```

Then remove the stray artifacts from the working tree:

```bash
rm -f webtranslateit-hpricot-0.9.0.gem webtranslateit-hpricot-0.10.0.gem
rm -rf ext
```

- [ ] **Step 6: Verify the gem builds and installs clean**

```bash
gem build hpricot.gemspec && gem spec webtranslateit-hpricot-1.0.0.gem extensions
```

Expected: builds successfully; `extensions` prints `[]`.

- [ ] **Step 7: Run everything**

```bash
rake test && rake determinism
```

Expected: all green, deterministic.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Remove the C and Java extensions

The pure-Ruby scanner replaces ext/hpricot_scan (C and Java) and
ext/fast_xs. The ragel grammar is kept under docs/grammar/ as the
specification the Ruby scanner was ported from.

Also drops setup.rb (unreferenced since before RubyGems) and .travis.yml
(Travis has been shut down for OSS; CI moves to GitHub Actions)."
```

---

## Task 14: CI

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [master]
  pull_request:

jobs:
  test:
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest]
        ruby: ['3.2', '3.3', '3.4', '4.0']
        include:
          - os: ubuntu-latest
            ruby: head
            experimental: true
    continue-on-error: ${{ matrix.experimental || false }}
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: ${{ matrix.ruby }}
          bundler-cache: true
      - run: bundle exec rake test

  determinism:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: '4.0'
          bundler-cache: true
      - run: bundle exec rake determinism

  jruby:
    runs-on: ubuntu-latest
    continue-on-error: true
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: jruby
          bundler-cache: true
      - run: bundle exec rake test
```

The `jruby` job is the payoff for dropping the Java implementation: the same Ruby code should now run there for free. It is `continue-on-error` until it is proven green.

- [ ] **Step 2: Update the Gemfile**

Replace `Gemfile` with:

```ruby
source 'https://rubygems.org'
gemspec
```

Delete the stale lockfile:

```bash
git rm --cached Gemfile.lock 2>/dev/null || true
rm -f Gemfile.lock
```

- [ ] **Step 3: Verify locally**

```bash
bundle install && bundle exec rake test
```

Expected: green.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml Gemfile
git add -u
git commit -m "Add GitHub Actions CI

Tests Ruby 3.2 through 4.0 on Linux and macOS, plus a determinism job and
a JRuby job that the pure-Ruby rewrite makes possible."
```

---

## Task 15: Performance gate

The measured baseline: C scanner 0.4ms on a 26KB file, 51.8ms on 1.5MB. A prototype Ruby tokenizer ran 3-5x slower. Confirm the real implementation lands in that range and decide whether it is acceptable.

**Files:**
- Create: `test/bench_scanner.rb`

- [ ] **Step 1: Write the benchmark**

Create `test/bench_scanner.rb`:

```ruby
# frozen_string_literal: true

require 'benchmark'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'hpricot'

fixture = ARGV[0] || File.expand_path('files/basic.xhtml', __dir__)
src = File.read(fixture)
unit = src[%r{<[^/!?][^>]*>.*?</[^>]+>}m] || '<a>x</a>'

[['baseline', src]].concat(
  [4, 32, 128].map { |mult| ["#{mult}x", src + (unit * mult)] }
).each do |label, s|
  n = s.bytesize > 500_000 ? 5 : 50
  t = Benchmark.realtime { n.times { Hpricot::XML(s) } } / n * 1000
  printf("%-10s %8dKB  %8.1fms  %6.1f MB/s\n",
         label, s.bytesize / 1024, t, (s.bytesize / 1024.0 / 1024.0) / (t / 1000.0))
end
```

- [ ] **Step 2: Run it against a real file**

```bash
ruby test/bench_scanner.rb /Users/edouard/code/language_file_handler/spec/language_file_handler/examples/xml/android/strings.xml
```

- [ ] **Step 3: Compare against the recorded C baseline**

| Input | C scanner | Acceptance ceiling (8x) |
|---|---|---|
| 26KB | 0.4ms | 3.2ms |
| 186KB | 3.7ms | 29.6ms |
| 1.5MB | 51.8ms | 414ms |

If the Ruby scanner is **within 8x**, accept it and finish. If it is **worse than 8x**, profile before optimising:

```bash
ruby -rprofile test/bench_scanner.rb 2>&1 | head -30
```

The likeliest cause is per-token `String` allocation. Two fixes in order of preference: (1) keep the hot loop entirely in `StringScanner#scan` (its matching is C — a char-by-char Ruby loop is an order of magnitude slower), and (2) store `[start, length]` integer pairs instead of eager `byteslice` copies, materializing `raw` lazily in the accessor.

- [ ] **Step 4: Record the result**

Append a `## Performance` section to `README.md` with the measured table and the Ruby-version/platform it was taken on.

- [ ] **Step 5: Commit**

```bash
git add test/bench_scanner.rb README.md
git commit -m "Add scanner benchmark and record measured performance"
```

---

## Task 16: Release

- [ ] **Step 1: Update the CHANGELOG**

Prepend to `CHANGELOG`:

```
== 1.0.0

* Replaced the C/ragel scanner and the parallel Java implementation with a
  pure-Ruby scanner. No native extension is built or shipped.
* Fixes, by construction, the memory-safety defects in the C scanner:
  nondeterministic parse results from an uninitialized read; segfaults on
  IO input at 16KB boundaries and on readers returning nil; an unbounded
  leak on every parse error; GC roots registered on dead stack frames.
* Input encoding is now preserved rather than forced to
  Encoding.default_external.
* An unknown encoding in an XML declaration is ignored rather than raising.
* Removed Hpricot.scan's block form (it segfaulted on any tag with an
  attribute) and Hpricot.css (its scanner dropped the last token of every
  selector; Elements#search has always used the Ruby implementation).
* Removed BlankSlate, which installed a process-wide Object.method_added
  hook. CssProxy now inherits from BasicObject.
* String#fast_xs is now Ruby. The C version's CP-1252 table was buggy.
* Requires Ruby >= 3.2. JRuby is supported by the same code.
```

- [ ] **Step 2: Verify the consumer still works**

```bash
cd /Users/edouard/code/language_file_handler
bundle config local.webtranslateit-hpricot /Users/edouard/code/github/hpricot
bundle install && bundle exec rspec 2>&1 | tail -20
```

Expected: the suite passes. **This is the acceptance test that matters most** — 26 call sites across 16 formats. Investigate any failure before releasing.

- [ ] **Step 3: Commit**

```bash
cd /Users/edouard/code/github/hpricot
git add CHANGELOG
git commit -m "Release 1.0.0"
```

---

## Self-review notes

**Deliberately deferred, not forgotten.** These are real defects found during review that this plan does not address, because they are independent of the scanner port:

- `lib/hpricot/tag.rb:21` — `html_quote` backslash-escapes quotes, which HTML does not honour, producing a live event handler from `Elem.new("a", {"href" => %q{x" onmouseover="alert(1)}})`. The `set_attribute` and `[]=` paths escape correctly, so only direct `Elem.new` construction is affected.
- `lib/hpricot/builder.rb:8-13` — `Hpricot.uxs` raises `RangeError` on `&#99999999999;`, emits invalid UTF-8 for surrogates, emits a NUL for `&#0;`, and raises `Encoding::CompatibilityError` on non-UTF-8 input.
- `lib/hpricot/traverse.rb:37,44,180`, `elements.rb:79`, `tag.rb:196` — `output("")` mutates a chilled string literal; `FrozenError` under `--enable=frozen-string-literal`.
- `lib/hpricot/traverse.rb:76` — a stray `p pos` prints to stdout from `nodes_at`.
- `lib/hpricot/traverse.rb:91-118` — `next`/`previous`/`preceding`/`following` dereference a nil parent before their guard runs.
- `lib/hpricot/elements.rb:295` — `search("nosuch:first")` returns `Elements[nil]`.
- `lib/hpricot/traverse.rb:749,765` — `Doc#title` and `#author` call methods that do not exist.

These are staged on branch `hardening-and-ci`. Land that branch before or after this plan, but do not mix it in — keeping the port diff free of unrelated fixes is what makes the differential harness trustworthy.

**Containment work belongs in `language_file_handler`, not here.** The parse currently runs before `security_valid?` (the `can_handle?` probe loop calls `Hpricot::XML` on raw uploaded bytes at `lib/language_file_handler.rb:130-143`), and no `rescue` guards any Hpricot call. That is worth fixing regardless of this port and is tracked separately.
