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

  # Number of times the legacy scanner is re-run to establish whether it is
  # self-consistent on a given input. The C scanner reads uninitialised memory
  # in its HTML-mode implicit-close path, so two runs agreeing proves nothing;
  # three or more disagreeing is what identifies an input as unusable as an
  # oracle. Raising this makes the harness stricter and slower.
  LEGACY_CONSISTENCY_RUNS = 4

  def assert_matches_legacy(path, xml:)
    unless DifferentialHelper.legacy_available?
      omit('set HPRICOT_LEGACY_TREE to a built pre-switchover checkout ' \
           '(see test/differential_helper.rb) to run the comparison')
    end

    legacy = DifferentialHelper.legacy_parse(path, xml: xml)

    # The old scanner crashing is a known defect, not a reason to fail the
    # port. Skip those inputs; test/test_robustness.rb asserts the new one
    # does NOT crash on them.
    omit("legacy scanner crashed on #{path}") if legacy == :crashed
    omit("legacy scanner raised on #{path}: #{legacy[1]}") if legacy.is_a?(Array)

    # Establish self-consistency BEFORE comparing anything. An oracle that
    # disagrees with itself cannot adjudicate the new scanner, and checking
    # only on mismatch made the result depend on which variant the oracle
    # happened to produce first -- which made this harness itself flaky.
    (LEGACY_CONSISTENCY_RUNS - 1).times do
      again = DifferentialHelper.legacy_parse(path, xml: xml)
      next unless again.is_a?(Hash)

      differing = %i[preserved serialized structure].find { |sig| again[sig] != legacy[sig] }
      next unless differing

      omit("legacy C scanner is nondeterministic on #{path} " \
           "(xml=#{xml}, #{differing}) - unusable as an oracle")
    end

    current = DifferentialHelper.current_parse(path, xml: xml)
    flunk("new scanner raised on #{path}: #{current[1]}") if current.is_a?(Array)

    %i[preserved serialized structure].each do |signal|
      assert_equal legacy[signal], current[signal],
                   "#{signal} differs for #{path} (xml=#{xml})"
    end
  end
end
