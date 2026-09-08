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
  # 2.0 and quadratic is 4.0. At these sizes the fixed code measures 1.91-2.19
  # across the cases below and the quadratic versions it replaced measure 3.67,
  # so 3.0 sits between them with roughly 30% margin on each side. Tighter than
  # that is not worth it: this is a guard against 10x-100x regressions, and a
  # threshold close to the linear measurement just makes the suite flaky.
  MAX_RATIO = 3.0

  # Sizes matter for reliability, not just speed. At 32k/64k a loaded CI runner
  # measured a linear case at 2.87 and failed this suite; the absolute times
  # there (0.03s/0.07s) were small enough for scheduling noise to dominate.
  # Doubling the sizes doubles the times and halves the relative noise.
  SMALL = 64_000
  LARGE = 128_000

  # Best-of-N. The minimum is the sample least contaminated by other work on
  # the machine, which is the failure mode being guarded against here.
  SAMPLES = 3

  # +small+/+large+ override the default sizes. Shapes that blow up steeply
  # need smaller inputs, or a quadratic run takes minutes to fail instead of
  # seconds -- a guard nobody will wait for is a guard nobody will keep.
  def assert_subquadratic(label, xml: false, small: SMALL, large: LARGE, &generate)
    small_t = SAMPLES.times.map { time(generate.call(small), xml: xml) }.min
    large_t = SAMPLES.times.map { time(generate.call(large), xml: xml) }.min

    # If even the large case is trivially fast, the ratio is measuring noise.
    # CPU time is stable enough for a lower floor than wall clock would need.
    return if large_t < 0.005

    small = small_t
    large = large_t

    ratio = large / small
    assert_operator ratio, :<, MAX_RATIO,
                    "#{label}: doubling the input multiplied time by " \
                    "#{format('%.1f', ratio)} (#{format('%.3f', small)}s -> " \
                    "#{format('%.3f', large)}s), which looks quadratic"
  end

  # Monotonic clock rather than Benchmark.realtime: benchmark stopped being a
  # default gem in Ruby 4.0, so requiring it fails under bundle exec unless it
  # is declared as a dependency, and a timing helper is not worth one.
  # CPU time, not wall clock. `min` over samples does not rescue a wall-clock
  # measurement when the two sizes see different contention -- on a loaded
  # machine a linear case measured a 3.82 ratio, a failure, because the small
  # side happened to get an uncontended slot. Under the same load CPU time gave
  # 2.37, restoring the margin this file assumes.
  def time(src, xml:)
    started = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
    xml ? Hpricot::XML(src) : Hpricot.parse(src)
    Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - started
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

  # doctype and procins scan forward for a terminator that may not exist. When
  # they bailed by rewinding to the construct's start, the whole tail was
  # rescanned once per construct. These two shapes were quadratic on master --
  # 1MB of the first took 264 seconds -- and shipped precisely because this
  # file guarded only attribute, text and tree-builder shapes.
  def test_doctype_without_a_terminator_is_linear
    assert_subquadratic('doctype, no terminator', xml: true, small: 8_000, large: 16_000) { |n| '<!DOCTYPE h SYSTEM "' * n }
  end

  def test_doctype_with_an_unclosed_internal_subset_is_linear
    assert_subquadratic('doctype, unclosed subset', xml: true, small: 8_000, large: 16_000) { |n| '<!DOCTYPE h [' * n }
  end

  # This one parses successfully, so it is not only the failure path that was
  # affected.
  def test_doctype_with_a_subset_and_a_terminator_is_linear
    assert_subquadratic('doctype, subset + >', xml: true, small: 8_000, large: 16_000) { |n| '<!DOCTYPE h [>' * n }
  end

  def test_unterminated_processing_instruction_is_linear
    assert_subquadratic('unterminated PI', xml: true, small: 8_000, large: 16_000) { |n| '<?x ' * n }
  end

  # The shape a truncated PHP upload takes.
  def test_unterminated_php_instruction_is_linear
    assert_subquadratic('unterminated <?php', xml: true, small: 8_000, large: 16_000) { |n| '<?php ' * n }
  end
end
