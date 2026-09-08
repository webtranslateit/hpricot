# frozen_string_literal: true

# Compares the legacy C scanner against the pure-Ruby scanner on a corpus.
#
# The C scanner runs in a subprocess: it segfaults on some inputs and we do not
# want that to kill the test run.
#
# THREE signals are compared, and all three matter:
#
#   1. to_original_html  - the preserved bytes. This is the byte-fidelity
#      requirement the port exists for.
#   2. to_html           - re-serialized from the tree. This is what catches a
#      WRONG TREE.
#   3. structure         - an explicit dump of class/name/attributes/nesting.
#
# Signal 1 alone is NOT sufficient, and relying on it was a real bug in an
# earlier version of this file. to_original_html emits each node's recorded raw
# source span verbatim, so it reproduces the input bytes even when the tree
# built from them is completely wrong. Measured on test/files/boingboing.html in
# HTML mode across 10 runs of the C scanner:
#
#   to_original_html: 128478 128478 128478 ...   (constant - masks the defect)
#   to_html:          129385 129387 129387 ...   (varies   - reveals it)
#
# A scanner that retained correct raw spans while nesting every element wrongly
# would pass signal 1 and fail signals 2 and 3. Keep all three.
require 'open3'

module DifferentialHelper
  REPO = File.expand_path('..', __dir__)

  # Files the corpus is drawn from: the shipped fixtures plus anything the
  # operator drops into test/corpus/ (real customer files, gitignored).
  def self.corpus_paths
    Dir[File.join(REPO, 'test/files/*')].select { |f| File.file?(f) } +
      Dir[File.join(REPO, 'test/corpus/**/*')].select { |f| File.file?(f) }
  end

  # Serializes a document into the three comparison signals. Defined as source
  # text so the subprocess and the in-process path run byte-identical code.
  SIGNATURE_SRC = <<~'RUBY'
    def __signature(doc)
      out = +''
      walk = lambda do |node, depth|
        out << ('  ' * depth) << node.class.name.sub('Hpricot::', '')
        out << ' ' << node.name.to_s if node.respond_to?(:name) && node.name.is_a?(String)
        if node.respond_to?(:raw_attributes) && node.raw_attributes.is_a?(Hash)
          # Sorted: attribute ORDER is compared via to_original_html, not here.
          out << ' {' << node.raw_attributes.sort_by { |k, _| k.to_s }
                             .map { |k, v| "#{k}=#{v.inspect}" }.join(',') << '}'
        end
        out << "\n"
        kids = node.respond_to?(:children) ? node.children : nil
        (kids || []).each { |c| walk.call(c, depth + 1) }
      end
      walk.call(doc, 0)
      out
    end
  RUBY

  # Defined on the singleton so DifferentialHelper.__signature works, and from
  # the same source string the subprocess evals, so both sides run identical code.
  singleton_class.class_eval(SIGNATURE_SRC) # rubocop:disable Security/Eval

  # Compared as bytes: corpus files include invalid UTF-8, and String#split
  # raises ArgumentError on those unless the encoding is BINARY.
  def self.signals(doc)
    { preserved: doc.to_original_html.dup.force_encoding(Encoding::BINARY),
      serialized: doc.to_html.dup.force_encoding(Encoding::BINARY),
      structure: __signature(doc).dup.force_encoding(Encoding::BINARY) }
  end

  # Runs the OLD C scanner out-of-process.
  #
  # ext/fast_xs must also be on $LOAD_PATH: builder.rb does `require 'fast_xs'`,
  # and without it Ruby resolves that to an installed hpricot gem's bundle
  # rather than the one built in this tree.
  #
  # Returns a Hash of signals, :crashed if the child died on a signal, or
  # [:error, msg] on a Ruby exception.
  def self.legacy_parse(path, xml:)
    script = <<~RUBY
      $LOAD_PATH.unshift(#{File.join(REPO, 'lib').inspect})
      $LOAD_PATH.unshift(#{File.join(REPO, 'ext/hpricot_scan').inspect})
      $LOAD_PATH.unshift(#{File.join(REPO, 'ext/fast_xs').inspect})
      require 'hpricot'
      #{SIGNATURE_SRC}
      doc = Hpricot.scan(File.binread(#{path.inspect}), #{xml ? '{ :xml => true }' : '{}'})
      $stdout.binmode
      # NUL-delimited: none of the three signals can contain a NUL byte.
      $stdout.write([doc.to_original_html, doc.to_html, __signature(doc)].join("\\0"))
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, '-e', script)
    return :crashed unless status.exited?
    return [:error, err.lines.first.to_s.strip] unless status.success?

    preserved, serialized, structure = out.force_encoding(Encoding::BINARY).split("\0", 3)
    { preserved: preserved.to_s, serialized: serialized.to_s, structure: structure.to_s }
  end

  # Runs the NEW Ruby scanner in-process.
  def self.current_parse(path, xml:)
    signals(Hpricot.scan(File.binread(path), xml ? { :xml => true } : {}))
  rescue StandardError => e
    [:error, "#{e.class}: #{e.message}"]
  end
end
