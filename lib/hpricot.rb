# == About hpricot.rb
#
# All of Hpricot's various part are loaded when you use <tt>require 'hpricot'</tt>.
#
# * hpricot_scan: the scanner (a C extension for Ruby) which turns an HTML stream into tokens.
# * hpricot/parse.rb: uses the scanner to sort through tokens and give you back a complete document object.
# * hpricot/tag.rb: sets up objects for the various types of elements in an HTML document.
# * hpricot/modules.rb: categorizes the various elements using mixins.
# * hpricot/traverse.rb: methods for searching documents.
# * hpricot/elements.rb: methods for dealing with a group of elements as an Hpricot::Elements list.
# * hpricot/inspect.rb: methods for displaying documents in a readable form.

# Load order matters. hpricot/nodes defines the node classes that tag.rb,
# modules.rb and traverse.rb reopen; if the old C extension were still loaded it
# would define those same classes first and `class Elem < ElemNode` would raise
# TypeError: superclass mismatch. There is no longer a native extension.
require 'hpricot/xs'
require 'hpricot/nodes'
require 'hpricot/htmlinfo'
require 'hpricot/scanner'
require 'hpricot/tree_builder'
require 'hpricot/tag'
require 'hpricot/modules'
require 'hpricot/traverse'
require 'hpricot/inspect'
require 'hpricot/parse'
require 'hpricot/builder'

module Hpricot
  # Raised when the scanner cannot make sense of its input. Retained from the C
  # extension for API compatibility; the Ruby scanner is liberal and does not
  # raise it, but downstream code rescues it.
  class ParseError < StandardError; end

  class << self
    # Retained for API compatibility. The C scanner read input through a
    # growable buffer of this size; the Ruby scanner reads the whole source.
    attr_accessor :buffer_size
  end

  # Parses +input+ (a String, or any object responding to #read) and returns a
  # Hpricot::Doc.
  #
  # Replaces the C singleton method of the same name. The old block form is not
  # supported: it dereferenced a NULL state pointer on any tag carrying an
  # attribute, and had no callers.
  def self.scan(input, opts = {})
    # Traverse#make passes the document's stored @options through, which is nil
    # for a document that was built rather than parsed.
    opts ||= {}
    source = input.respond_to?(:read) ? input.read.to_s : input.to_s
    kw = { xml: !!opts[:xml],
           fixup_tags: !!opts[:fixup_tags],
           xhtml_strict: !!opts[:xhtml_strict] }
    TreeBuilder.new(Scanner.new(source, **kw).tokens, **kw).document
  end
end
