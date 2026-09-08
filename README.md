# webtranslateit-hpricot

A maintained fork of [hpricot](https://github.com/hpricot/hpricot), _why the
lucky stiff's HTML/XML parser. Upstream was declared over in 2013; this fork
exists because [WebTranslateIt](https://webtranslateit.com) still depends on it
and intends to keep it working.

## Why this fork exists

We parse translation and localisation files — `.resx`, `.xml`, `.ts`, `.tbx`,
`.stringsdict`, `.xtb`, `.docx`, and a dozen more — and hand them back to
customers after editing. That imposes a requirement most parsers do not meet:

**Byte-identical round-tripping.** If a customer's file writes `&#8230;` we must
give back `&#8230;`, not `…`. If it writes `&quot;` we must give back `&quot;`,
not `"`. If it orders attributes a certain way, that order must survive. A
translation tool that silently reformats the untouched 99% of a file is worse
than useless — it turns every export into an unreviewable diff.

We measured the alternatives against a real corpus:

| Parser | Preserves `&#8230;` | Preserves `&quot;` | Preserves attribute order | Byte-identical |
|---|---|---|---|---|
| hpricot | yes | yes | yes | **yes** |
| Nokogiri | only via `encoding: 'US-ASCII'`, all-or-nothing | no | yes | no |
| Oga | no | no | yes | no |
| REXML (`raw: :all`) | yes | yes | **no** | no |

Hpricot manages this because it does not decode. It records the source byte span
of every node and emits those bytes verbatim for anything you did not modify.
Fidelity is a property of *not* re-encoding, and re-encoding is exactly what a
conformant serializer must do.

The second requirement is **liberality**. Hpricot accepts malformed markup that
a conformant parser rejects. Real uploaded files are frequently malformed, and
"your file is invalid" is not an acceptable answer when the previous version of
the product accepted it. A prior attempt to move to REXML foundered on precisely
this — it correctly rejected files hpricot tolerated.

Hpricot is also the fastest of the four we measured (~1.6x Nokogiri), though
that is the least important reason: parsing is well under half the cost of a
typical import job.

## Current state

The library works and is in production. The Ruby layer is actively maintained.

**The C extension is being replaced with pure Ruby.** The scanner is a
ragel-generated C state machine that has had no upstream maintenance since 2013,
and a review turned up several memory-safety defects: an uninitialised read that
makes HTML-mode parsing non-deterministic across processes, two reachable
segfaults, an unbounded leak on parse errors, and GC roots registered against
dead stack frames. It also no longer compiles on Ruby trunk.

Since parsing is not the bottleneck, there is no reason to keep hand-patched C
in a library that consumes untrusted input. A pure-Ruby scanner eliminates that
entire class of defect by construction, removes the parallel Java implementation
maintained for JRuby, and means no native extension to rebuild on every Ruby
release. The plan is in
[`docs/superpowers/plans/`](docs/superpowers/plans/2026-09-08-pure-ruby-scanner.md).

Byte-identical round-tripping and liberality are the acceptance criteria for
that work, verified by a differential harness that compares the new scanner
against the old C one on a corpus of real files.

## Installing

    $ gem install webtranslateit-hpricot

Or in a Gemfile:

```ruby
gem 'webtranslateit-hpricot'
```

The API is hpricot's — `require 'hpricot'` and everything below applies
unchanged.

## Performance

Measured on Ruby 4.0.6, arm64-darwin, parsing a real Android `strings.xml`
fixture scaled up by repeating its `<string>` elements. `Hpricot::XML`, mean of
several runs.

| Input | C/ragel scanner | pure Ruby | + YJIT | ratio (YJIT) |
|---|---|---|---|---|
| 26 KB | 0.4 ms | 2.3 ms | 1.8 ms | 4.5x |
| 186 KB | 4.3 ms | 22.8 ms | 15.7 ms | 3.7x |
| 1.5 MB | 45.4 ms | 190.6 ms | 151.3 ms | 3.3x |
| 5 MB | 153.2 ms | 716.5 ms | 554.4 ms | 3.6x |

Both are linear. YJIT is worth roughly 25-30% and needs no code change. Parsing
is under half the cost of even parse-plus-extract, before encoding detection,
entity decoding or database work, so it is not the bottleneck in any real
pipeline.

### Malformed input: faster than the C scanner

The table above is well-formed input, where C wins. On malformed input the
pure-Ruby scanner is now **considerably faster**, because several quadratic
behaviours were fixed during the port that the C scanner still has:

| Input | C/ragel scanner | pure Ruby |
|---|---|---|
| 97 KB of nested `<div>` | 1.73 s | 0.062 s |
| 78 KB of `<a>` inside `<button>` | 1.58 s | 0.070 s |
| 214 KB of unmatched end tags | 2.85 s | 0.077 s |

These are not micro-optimisations: the same shapes were quadratic here too at
various points during the port, at up to 77 seconds for 156 KB. Since this
library parses untrusted uploads, an O(n²) input shape is a denial-of-service
vector rather than a slow path, so `test/test_complexity.rb` asserts the
scaling ratio for each of them and fails if any becomes quadratic again.

### Where the time goes

Scanning is ~80% of parse time and tree building ~20%. Profiling the scanner
puts GC at 22% of samples (13.9% sweeping, 7.7% marking) and `String#byteslice`
at another 10%, so allocation pressure dominates and that is where tuning has
to aim.

What worked:

* Dispatching on the first byte, so a text token does not attempt four
  construct regexes before falling through.
* `StringScanner#skip` instead of `#scan` wherever the matched text is
  discarded — `scan` allocates a String for the match even when only its
  success matters.
* Matching a whole attribute in one scan rather than six calls, using the
  capture groups directly instead of separate byteslices (~5%).
* Not copying the document. A source already valid in an ASCII-compatible
  encoding is scanned in place: `StringScanner#pos` and `#skip` are
  byte-oriented whatever the encoding, and the character classes here are all
  ASCII-only. This removes two full-document copies per parse — the scanning
  buffer and a re-encoded copy for slicing — so a 5 MB upload no longer
  allocates 10 MB of copies. Peak RSS is dominated by the parse tree, so this
  does not show up there; it is an allocation win, not a footprint one.

What did not work, measured and reverted: interning repeated tag names and
attribute keys. `string` and `name` recur thousands of times in a translation
file, but the lookup still allocates the temporary it searches with, so the
allocation count was unchanged and the hash probe cost as much as it saved.

### Why this is viable now and was not in 2006

Hpricot was written in 2006 against Ruby 1.8, a tree-walking interpreter with
no bytecode VM. A pure-Ruby scanner then would have been perhaps an order of
magnitude slower than this one, which is a large part of why the scanner was
written in C to begin with. Ruby 1.9 brought YARV, 2.x brought generational and
incremental GC, and 3.x brought YJIT. The trade-off that justified a C extension
in 2006 simply does not hold in 2026: this scanner parses a 1.5 MB document in
130 ms, which is comfortably faster in absolute terms than the original C
extension managed on the hardware it was written for.

### "Pure Ruby" — what that does and does not mean

The hot loop runs inside `StringScanner#scan`, and `strscan` is implemented in C
in CRuby. So C still executes; what changed is *whose* C it is.

What was removed is this project's own native code: roughly 7,000 lines of
ragel-generated C plus a hand-written scanner, a parallel Java implementation
for JRuby, and `fast_xs`. That code had no upstream maintainer after 2013, could
not be regenerated without ragel (which nobody had installed), had to be
recompiled for every Ruby and platform, and had been hand-patched in the
generated output. A review of it found an uninitialised read, two reachable
segfaults, an unbounded leak and GC roots registered on dead stack frames. It
also stopped compiling on Ruby trunk.

`strscan` is a different proposition: it ships with Ruby, is maintained and
fuzzed by ruby-core, gets security fixes without us doing anything, and has an
implementation on every engine — which is why JRuby now works from the same
source with no Java of ours.

So the accurate claim is **no native extension of our own**: nothing is
compiled at install time, there is no `extensions` entry in the gemspec, no
ragel, and no platform-specific builds. A character-by-character Ruby loop
would be an order of magnitude slower than `StringScanner`, so keeping the hot
loop inside it is a deliberate design constraint.

## Contributing

Issues and pull requests are welcome, though be aware this fork is maintained
for a specific purpose and changes are weighed against that. If you want a
general-purpose HTML parser, use
[Nokogiri](https://github.com/sparklemotion/nokogiri) — it is better maintained,
standards-compliant, and almost certainly what you want.

Thanks to \_why for all the fun. We'll never forget it.

---


# Hpricot, Read Any HTML

Hpricot is a fast, flexible HTML parser written in C.  It's designed to be very
accommodating (like Tanaka Akira's HTree) and to have a very helpful library
(like some JavaScript libs -- JQuery, Prototype -- give you.)  The XPath and CSS
parser, in fact, is based on John Resig's JQuery.

Also, Hpricot can be handy for reading broken XML files, since many of the same
techniques can be used.  If a quote is missing, Hpricot tries to figure it out.
If tags overlap, Hpricot works on sorting them out.  You know, that sort of
thing.

*Please read this entire document* before making assumptions about how this
software works.

## An Overview

Let's clear up what Hpricot is.

* Hpricot is *a standalone library*.  It requires no other libraries.  Just Ruby!
* While priding itself on speed, Hpricot *works hard to sort out bad HTML* and
  pays a small penalty in order to get that right.  So that's slightly more important
  to me than speed.
* *If you can see it in Firefox, then Hpricot should parse it.*  That's
  how it should be!  Let me know the minute it's otherwise.
* Primarily, Hpricot is used for reading HTML and tries to sort out troubled
  HTML by having some idea of what good HTML is.  Some people still like to use
  Hpricot for XML reading, but *remember to use the Hpricot::XML() method* for that!

## The Hpricot Kingdom

First, here are all the links you need to know:

* http://wiki.github.com/hpricot/hpricot is the Hpricot wiki and
  http://github.com/hpricot/hpricot/issues is the bug tracker.
  Go there for news and recipes and patches.  It's the center of activity.
* http://github.com/hpricot/hpricot is the main Git
  repository for Hpricot.  You can get the latest code there.
* See COPYING for the terms of this software. (Spoiler: it's absolutely free.)

If you have any trouble, don't hesitate to contact the author.  As always, I'm
not going to say "Use at your own risk" because I don't want this library to be
risky.  If you trip on something, I'll share the liability by repairing things
as quickly as I can.  Your responsibility is to report the inadequacies.

## An Hpricot Showcase

We're going to run through a big pile of examples to get you jump-started.
Many of these examples are also found at
http://wiki.github.com/hpricot/hpricot/hpricot-basics, in case you
want to add some of your own.

### Loading Hpricot Itself

You have probably got the gem, right?  To load Hpricot:

    require 'rubygems'
    require 'hpricot'

If you've installed the plain source distribution, go ahead and just:

    require 'hpricot'

### Load an HTML Page

The <tt>Hpricot()</tt> method takes a string or any IO object and loads the
contents into a document object.

    doc = Hpricot("<p>A simple <b>test</b> string.</p>")

To load from a file, just get the stream open:

    doc = open("index.html") { |f| Hpricot(f) }

To load from a web URL, use <tt>open-uri</tt>, which comes with Ruby:

    require 'open-uri'
    doc = open("http://qwantz.com/") { |f| Hpricot(f) }

Hpricot uses an internal buffer to parse the file, so the IO will stream
properly and large documents won't be loaded into memory all at once.  However,
the parsed document object will be present in memory, in its entirety.

### Search for Elements

Use <tt>Doc.search</tt>:

    doc.search("//p[@class='posted']")
    #=> #<Hpricot:Elements[{p ...}, {p ...}]>

<tt>Doc.search</tt> can take an XPath or CSS expression.  In the above example,
all paragraph <tt><p></tt> elements are grabbed which have a <tt>class</tt>
attribute of <tt>"posted"</tt>.

A shortcut is to use the divisor:

    (doc/"p.posted")
    #=> #<Hpricot:Elements[{p ...}, {p ...}]>

### Finding Just One Element

If you're looking for a single element, the <tt>at</tt> method will return the
first element matched by the expression.  In this case, you'll get back the
element itself rather than the <tt>Hpricot::Elements</tt> array.

    doc.at("body")['onload']

The above code will find the body tag and give you back the <tt>onload</tt>
attribute.  This is the most common reason to use the element directly: when
reading and writing HTML attributes.

### Fetching the Contents of an Element

Just as with browser scripting, the <tt>inner_html</tt> property can be used to
get the inner contents of an element.

    (doc/"#elementID").inner_html
    #=> "..contents.."

If your expression matches more than one element, you'll get back the contents
of ''all the matched elements''.  So you may want to use <tt>first</tt> to be
sure you get back only one.

    (doc/"#elementID").first.inner_html
    #=> "..contents.."

### Fetching the HTML for an Element

If you want the HTML for the whole element (not just the contents), use
<tt>to_html</tt>:

    (doc/"#elementID").to_html
    #=> "<div id='elementID'>...</div>"

### Looping

All searches return a set of <tt>Hpricot::Elements</tt>.  Go ahead and loop
through them like you would an array.

    (doc/"p/a/img").each do |img|
      puts img.attributes['class']
    end

### Continuing Searches

Searches can be continued from a collection of elements, in order to search deeper.

    # find all paragraphs.
    elements = doc.search("/html/body//p")
    # continue the search by finding any images within those paragraphs.
    (elements/"img")
    #=> #<Hpricot::Elements[{img ...}, {img ...}]>

Searches can also be continued by searching within container elements.

    # find all images within paragraphs.
    doc.search("/html/body//p").each do |para|
      puts "== Found a paragraph =="
      pp para

      imgs = para.search("img")
      if imgs.any?
        puts "== Found #{imgs.length} images inside =="
      end
    end

Of course, the most succinct ways to do the above are using CSS or XPath.

    # the xpath version
    (doc/"/html/body//p//img")
    # the css version
    (doc/"html > body > p img")
    # ..or symbols work, too!
    (doc/:html/:body/:p/:img)

### Looping Edits

You may certainly edit objects from within your search loops.  Then, when you
spit out the HTML, the altered elements will show.


    (doc/"span.entryPermalink").each do |span|
      span.attributes['class'] = 'newLinks'
    end
    puts doc

This changes all <tt>span.entryPermalink</tt> elements to
<tt>span.newLinks</tt>.  Keep in mind that there are often more convenient ways
of doing this.  Such as the <tt>set</tt> method:

    (doc/"span.entryPermalink").set(:class => 'newLinks')

### Figuring Out Paths

Every element can tell you its unique path (either XPath or CSS) to get to the
element from the root tag.

The <tt>css_path</tt> method:

    doc.at("div > div:nth(1)").css_path
      #=> "div > div:nth(1)" 
    doc.at("#header").css_path
      #=> "#header" 

Or, the <tt>xpath</tt> method:

    doc.at("div > div:nth(1)").xpath
      #=> "/div/div:eq(1)" 
    doc.at("#header").xpath
      #=> "//div[@id='header']"

## Hpricot Fixups

When loading HTML documents, you have a few settings that can make Hpricot more
or less intense about how it gets involved.

## :fixup_tags

Really, there are so many ways to clean up HTML and your intentions may be to
keep the HTML as-is.  So Hpricot's default behavior is to keep things flexible.
Making sure to open and close all the tags, but ignore any validation problems.

As of Hpricot 0.4, there's a new <tt>:fixup_tags</tt> option which will attempt
to shift the document's tags to meet XHTML 1.0 Strict.

    doc = open("index.html") { |f| Hpricot f, :fixup_tags => true }

This doesn't quite meet the XHTML 1.0 Strict standard, it just tries to follow
the rules a bit better.  Like: say Hpricot finds a paragraph in a link, it's
going to move the paragraph below the link.  Or up and out of other elements
where paragraphs don't belong.

If an unknown element is found, it is ignored.  Again, <tt>:fixup_tags</tt>.

## :xhtml_strict

So, let's go beyond just trying to fix the hierarchy.  The
<tt>:xhtml_strict</tt> option really tries to force the document to be an XHTML
1.0 Strict document.  Even at the cost of removing elements that get in the way.

    doc = open("index.html") { |f| Hpricot f, :xhtml_strict => true }

What measures does <tt>:xhtml_strict</tt> take?

 1. Shift elements into their proper containers just like :fixup_tags.
 2. Remove unknown elements.
 3. Remove unknown attributes.
 4. Remove illegal content.
 5. Alter the doctype to XHTML 1.0 Strict.

## Hpricot.XML()

The last option is the <tt>:xml</tt> option, which makes some slight variations
on the standard mode.  The main difference is that :xml mode won't try to output
tags which are friendlier for browsers.  For example, if an opening and closing
<tt>br</tt> tag is found, XML mode won't try to turn that into an empty element.

XML mode also doesn't downcase the tags and attributes for you.  So pay attention
to case, friends.

The primary way to use Hpricot's XML mode is to call the Hpricot.XML method:

    doc = open("http://redhanded.hobix.com/index.xml") do |f|
      Hpricot.XML(f)
    end

*Also, :fixup_tags is canceled out by the :xml option.*  This is because
:fixup_tags makes assumptions based how HTML is structured.  Specifically, how
tags are defined in the XHTML 1.0 DTD.
