# frozen_string_literal: true

require 'test/unit'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'hpricot'

# Guards against quadratic blow-up on malformed input.
#
# This gem parses untrusted uploads, so an input shape that costs O(n^2) is a
# denial-of-service vector, not merely a slow path. Each case below was
# genuinely quadratic at some point during the pure-Ruby port; the worst took
# 77 seconds for 156KB.
#
# These assert a SCALING RATIO rather than absolute times, so they do not fail
# on a slow or loaded CI machine. Doubling the input should roughly double the
# work; quadratic behaviour quadruples it. The bound is deliberately loose --
# the failures being guarded against are 10x-100x, not 2x.
class TestComplexity < Test::Unit::TestCase
  # Doubling the input must not multiply the time by more than this. Linear is
  # 2.0 and quadratic is 4.0; measured at these sizes the fixed code runs at
  # ~1.9 and the quadratic version it replaced at ~3.5, so 2.8 separates them
  # with margin on both sides.
  MAX_RATIO = 2.8

  # Chosen so the quadratic/linear gap is unambiguous while a passing run stays
  # well under a second per case. Smaller inputs did not separate the two.
  SMALL = 32_000
  LARGE = 64_000

  def assert_subquadratic(label, xml: false, &generate)
    # Best of three at each size: a single sample is too noisy on a shared CI
    # runner, and the minimum is the least contaminated by scheduling.
    small = 3.times.map { time(generate.call(SMALL), xml: xml) }.min
    large = 3.times.map { time(generate.call(LARGE), xml: xml) }.min

    # If even the large case is trivially fast, the ratio is measuring noise.
    return if large < 0.02

    ratio = large / small
    assert_operator ratio, :<, MAX_RATIO,
                    "#{label}: doubling the input multiplied time by " \
                    "#{format('%.1f', ratio)} (#{format('%.3f', small)}s -> " \
                    "#{format('%.3f', large)}s), which looks quadratic"
  end

  # Monotonic clock rather than Benchmark.realtime: benchmark stopped being a
  # default gem in Ruby 4.0, so requiring it fails under bundle exec unless it
  # is declared as a dependency, and a timing helper is not worth one.
  def time(src, xml:)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    xml ? Hpricot::XML(src) : Hpricot.parse(src)
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  # Unquoted attribute values must not swallow '<'. When they did, the
  # attribute loop ran to EOF and every subsequent '<' rescanned the same tail.
  def test_unquoted_attribute_values_are_linear
    assert_subquadratic('unquoted attribute values', xml: true) { |n| '<a href=x' * n }
  end

  # Adjacent text nodes are merged; rebuilding the accumulated string each time
  # made ordinary prose containing '<' quadratic.
  def test_adjacent_text_merging_is_linear
    assert_subquadratic('adjacent text', xml: true) { |n| 'a < b ' * n }
  end

  def test_bare_less_than_is_linear
    assert_subquadratic('bare <', xml: true) { |n| '<' * n }
  end

  # End tags matching no open element are the common case in malformed input;
  # scanning the whole open-element stack for each was quadratic.
  def test_unmatched_end_tags_are_linear
    assert_subquadratic('unmatched end tags', xml: true) { |n| ('<x:a>' * n) + ('</zzz>' * n) }
  end

  # The HTML implicit-close walk climbs to the root by design, because an
  # :allow/:deny on an outer ancestor overrides an inner match.
  def test_deep_nesting_is_linear
    assert_subquadratic('nested div') { |n| '<div>' * n }
  end

  # ... and the same, wrapped in a tag that DOES carry overrides, which
  # defeated a first attempt at the fix.
  def test_deep_nesting_inside_an_overriding_tag_is_linear
    assert_subquadratic('spans in button') { |n| "<button>#{'<span>' * n}<a>x" }
  end

  # The case where the override genuinely applies to the tag being opened.
  def test_repeated_excluded_tag_inside_an_overriding_tag_is_linear
    assert_subquadratic('a in button') { |n| "<button>#{'<a>x' * n}" }
  end
end
