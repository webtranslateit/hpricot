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

    return if legacy.bytesize == current.bytesize && legacy == current

    # A mismatch here is not automatically a real failure. The C scanner is
    # known to be nondeterministic on large inputs (an uninitialized read —
    # see the plan doc), so the SAME file can serialize differently across
    # two subprocess runs of the legacy scanner alone. This matters most
    # while both sides of the comparison are still the C extension (the
    # Task 2 sanity check): without this guard, boingboing.html would fail
    # the harness for a reason that has nothing to do with the harness or
    # the new scanner. Re-run the legacy side a second time, out-of-process,
    # and only treat the mismatch as real if the C scanner agrees with
    # itself.
    legacy_again = DifferentialHelper.legacy_parse(path, xml: xml)
    if legacy_again == :crashed || legacy_again.is_a?(Array) || legacy_again != legacy
      omit("legacy C scanner is nondeterministic on #{path} (xml=#{xml}): " \
           "two subprocess runs of the SAME legacy scanner produced " \
           "different output, so the mismatch against the new scanner is " \
           "not meaningful")
    end

    assert_equal legacy.bytesize, current.bytesize,
                 "byte length differs for #{path} (xml=#{xml})"
    assert_equal legacy, current,
                 "output differs for #{path} (xml=#{xml})"
  end
end
