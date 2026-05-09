# frozen_string_literal: true
require_relative "test_helper"
require "reline/dialog_transform/chain"

# Phase 2.5 RED — Chain#call execution semantics, per spec §5.2.
#
# Chain runs transforms in order, each receiving (text, ctx) and
# returning text passed to the next. error_isolation default true
# means a raising transform falls through (input passes unchanged
# to the next), so a single broken transform doesn't kill the dialog.
class ChainTest < Test::Unit::TestCase
  Chain = Reline::DialogTransform::Chain

  def test_no_transforms_returns_input_unchanged
    chain = Chain.new([])
    assert_equal "hello", chain.call("hello", {})
  end

  def test_single_proc_applies_to_text
    chain = Chain.new([->(t, _) { t.upcase }])
    assert_equal "HELLO", chain.call("hello", {})
  end

  def test_multiple_procs_apply_in_order
    chain = Chain.new([
      ->(t, _) { t.upcase },
      ->(t, _) { t + "!" }
    ])
    assert_equal "HELLO!", chain.call("hello", {})
  end

  def test_each_transform_receives_ctx
    seen = []
    chain = Chain.new([
      ->(t, c) { seen << c; t },
      ->(t, c) { seen << c; t }
    ])
    ctx = { source: :rdoc, identifier: "x" }
    chain.call("x", ctx)
    assert_equal [ctx, ctx], seen
  end

  def test_raising_transform_falls_through_when_error_isolation_default
    chain = Chain.new([
      ->(_, _) { raise "boom" },
      ->(t, _) { t.upcase }
    ])
    # error_isolation default true: failure of step 1 leaves text
    # unchanged for step 2, which still upcases the original input.
    assert_equal "HELLO", chain.call("hello", {})
  end

  def test_error_isolation_false_propagates_raised_error
    chain = Chain.new([
      ->(_, _) { raise "boom" }
    ], error_isolation: false)
    assert_raise(RuntimeError) { chain.call("hello", {}) }
  end

  def test_transforms_accessor_still_returns_array
    p1 = ->(t, _) { t }
    chain = Chain.new([p1])
    assert_equal [p1], chain.transforms
  end
end
