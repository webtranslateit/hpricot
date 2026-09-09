# == About hpricot.rb
#
# All of Hpricot's various part are loaded when you use <tt>require 'hpricot'</tt>.
#
# * hpricot/scanner.rb: turns an HTML/XML stream into tokens, each keeping its source bytes.
# * hpricot/tree_builder.rb: assembles those tokens into a document tree.
# * hpricot/nodes.rb: the node classes.
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
    # Traverse#make passes the document's stored @options through, e.g. so a
    # fragment inserted with Elem#after into an XML document is itself parsed
    # in XML mode. hpricot_scan.rl:528 set this same ivar on the C scanner's
    # document; without it, Doc#make (hpricot/tag.rb) always falls back to
    # HTML-mode parsing for inserted fragments.
    opts ||= {}
    source = input.respond_to?(:read) ? input.read.to_s : input.to_s
    kw = { xml: !!opts[:xml],
           fixup_tags: !!opts[:fixup_tags],
           xhtml_strict: !!opts[:xhtml_strict],
           html_void: !!opts[:html_void],
           void_elements: void_element_set(opts[:void_elements]) }
    doc = TreeBuilder.new(Scanner.new(source, **kw).tokens, **kw).document
    doc.instance_variable_set(:@options, opts)
    doc
  end

  # Normalises the :void_elements option into a name => true lookup.
  #
  # nil means the option was not given, and TreeBuilder falls back to
  # :html_void. An explicit empty list is a different statement -- "no element
  # is void" -- so it normalises to an empty Hash, which is truthy and
  # therefore overrides :html_void the way any other explicit set does.
  #
  # Names are matched exactly. XML is case sensitive, and this option exists
  # for XML mode, so a set naming 'br' does not cover '<BR>'.
  def self.void_element_set(names)
    return nil if names.nil?

    Array(names).each_with_object({}) { |name, set| set[name.to_s] = true }.freeze
  end
  private_class_method :void_element_set
end
