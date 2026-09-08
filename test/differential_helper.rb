# frozen_string_literal: true

# Compares the legacy C scanner against the pure-Ruby scanner on a corpus.
#
# The C scanner is loaded in a subprocess (it segfaults on some inputs and we
# do not want that to kill the test run). Both sides serialize with
# to_original_html (Traverse#to_html takes no arguments in this codebase; the
# "preserve raw bytes" flavour is a separate method, see
# lib/hpricot/traverse.rb and test/test_preserved.rb) and we assert the bytes
# match exactly.
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
  #
  # ext/fast_xs must also be on $LOAD_PATH: builder.rb does `require 'fast_xs'`,
  # and without it Ruby happily resolves that to an installed hpricot gem's
  # bundle instead of the one built in this tree.
  def self.legacy_parse(path, xml:)
    script = <<~RUBY
      $LOAD_PATH.unshift(#{File.join(REPO, 'lib').inspect})
      $LOAD_PATH.unshift(#{File.join(REPO, 'ext/hpricot_scan').inspect})
      $LOAD_PATH.unshift(#{File.join(REPO, 'ext/fast_xs').inspect})
      require 'hpricot'
      src = File.binread(#{path.inspect})
      doc = Hpricot.scan(src, #{xml ? '{ :xml => true }' : '{}'})
      $stdout.binmode
      $stdout.write(doc.to_original_html)
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
    doc.to_original_html
  rescue StandardError => e
    [:error, "#{e.class}: #{e.message}"]
  end
end
