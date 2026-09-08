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
    # port. Skip those inputs; test/test_robustness.rb asserts the new one
    # does NOT crash on them.
    omit("legacy scanner crashed on #{path}") if legacy == :crashed
    omit("legacy scanner raised on #{path}: #{legacy[1]}") if legacy.is_a?(Array)

    current = DifferentialHelper.current_parse(path, xml: xml)
    flunk("new scanner raised on #{path}: #{current[1]}") if current.is_a?(Array)

    %i[preserved serialized structure].each do |signal|
      if legacy[signal] != current[signal]
        # Before reporting a mismatch, check the C scanner against ITSELF. It
        # reads uninitialised memory in the HTML-mode implicit-close path, so a
        # difference here may be the old scanner disagreeing with its own
        # previous run rather than the new one being wrong.
        second = DifferentialHelper.legacy_parse(path, xml: xml)
        if second.is_a?(Hash) && second[signal] != legacy[signal]
          omit("legacy C scanner is nondeterministic on #{path} (xml=#{xml}, #{signal})")
        end
      end

      # Asserted unconditionally so a passing comparison still records an
      # assertion; a test that asserts nothing is indistinguishable from a
      # test that silently did no work.
      assert_equal legacy[signal], current[signal],
                   "#{signal} differs for #{path} (xml=#{xml})"
    end
  end
end
