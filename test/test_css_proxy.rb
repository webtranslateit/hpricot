# -*- coding: utf-8 -*-
#!/usr/bin/env ruby

require 'test/unit'
require 'hpricot'

# Records calls made to Builder#tag! without pulling in the whole Builder
# machinery, so CssProxy can be exercised in isolation.
class FakeBuilder
  attr_reader :calls

  def initialize
    @calls = []
  end

  def tag!(sym, *args, &block)
    @calls << [sym, args, block]
    :tagged
  end
end

class TestCssProxy < Test::Unit::TestCase
  def setup
    @fake = FakeBuilder.new
    @proxy = Hpricot::CssProxy.new(@fake, :div)
  end

  def test_inherits_from_basic_object
    assert_equal ::BasicObject, ::Hpricot::CssProxy.superclass
  end

  def test_blankslate_is_gone
    assert_raise(NameError) { ::Hpricot::BlankSlate }
  end

  def test_method_without_bang_adds_a_css_class
    result = @proxy.foo
    assert_same @proxy, result
    assert_equal [], @fake.calls
  end

  def test_method_with_bang_sets_the_id
    result = @proxy.foo!
    assert_same @proxy, result
    assert_equal [], @fake.calls
  end

  def test_chaining_classes_and_id_then_finalizing_with_a_block
    block = proc { }
    result = @proxy.alpha.beta.gamma!(&block)

    assert_equal :tagged, result
    assert_equal 1, @fake.calls.size
    sym, args, captured_block = @fake.calls.first
    assert_equal :div, sym
    assert_equal [{ :class => "alpha beta", :id => "gamma" }], args
    assert_same block, captured_block
  end

  def test_finalizing_with_args_instead_of_a_block
    result = @proxy.item("payload")

    assert_equal :tagged, result
    sym, args, block = @fake.calls.first
    assert_equal :div, sym
    assert_equal ["payload", { :class => "item" }], args
    assert_nil block
  end

  # This is the whole point of inheriting from BasicObject instead of the
  # broken BlankSlate: method names that collide with real Object/Kernel
  # methods (which BlankSlate's buggy `hide` never actually removed) must
  # still be captured by method_missing and treated as CSS class/id names.
  def test_object_method_names_are_captured_as_css_classes_or_ids
    result = @proxy.class.hash.object_id.inspect.freeze!(&proc { })

    assert_equal :tagged, result
    sym, args, block = @fake.calls.first
    assert_equal :div, sym
    assert_equal [{ :class => "class hash object_id inspect", :id => "freeze" }], args
  end

  def test_full_builder_dsl_with_colliding_names
    doc = Hpricot() { div.class.id! { text "x" } }
    assert_equal %{<div class="class" id="id">x</div>}, doc.to_html
  end
end
