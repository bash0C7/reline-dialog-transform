# frozen_string_literal: true
require_relative "test_helper"
require "reline/dialog_transform/builder"

# Spec: 2026-05-09-dsl-unification-design.md §2 E2 + §3.1.
# Builder is a pure array-push wrapper. No slot tracking, no dedup,
# no clear!, no DSL default_lang method. default_lang flows through
# the constructor kwarg and is forwarded into translate when
# target_lang is omitted.
class BuilderTest < Test::Unit::TestCase
  Builder   = Reline::DialogTransform::Builder
  Translate = Reline::DialogTransform::Translate

  def test_translate_called_twice_appends_both
    b = Builder.new
    b.translate target_lang: :ja
    b.translate target_lang: :en

    transforms = b.to_chain.transforms
    assert_equal 2, transforms.size
    assert_equal :ja, transforms[0].target_lang
    assert_equal :en, transforms[1].target_lang
  end

  def test_use_called_twice_appends_both_in_order
    b = Builder.new
    p1 = ->(text, _ctx) { text.upcase }
    p2 = ->(text, _ctx) { text.reverse }
    b.use p1
    b.use p2

    assert_equal [p1, p2], b.to_chain.transforms
  end

  def test_default_lang_kwarg_propagates_into_translate
    b = Builder.new(default_lang: :ja)
    b.translate

    assert_equal :ja, b.to_chain.transforms.first.target_lang
  end

  def test_explicit_target_lang_overrides_default_lang
    b = Builder.new(default_lang: :ja)
    b.translate target_lang: :en

    assert_equal :en, b.to_chain.transforms.first.target_lang
  end

  def test_no_default_lang_translate_target_lang_stays_nil
    b = Builder.new
    b.translate

    assert_nil b.to_chain.transforms.first.target_lang
  end

  def test_use_does_not_affect_other_transforms
    b = Builder.new
    callable = ->(t, _) { t }
    b.translate
    b.use callable
    b.use ->(t, _) { t }

    transforms = b.to_chain.transforms
    assert_equal 3, transforms.size
    assert_kind_of Translate, transforms[0]
    assert_same   callable,    transforms[1]
  end
end
