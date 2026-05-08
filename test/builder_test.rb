# frozen_string_literal: true
require_relative "test_helper"
require "reline/dialog_transform/builder"

# Phase 1 RED — slot replacement semantics for the DSL Builder, per
# 2026-05-08-reline-dialog-transform-design.md §4 Decision E and §5.2.
#
# Slot rules:
#   - Same Transform class (translate, speak): later call REPLACES earlier
#     in the same position. (no duplicate slots, position preserved)
#   - Anonymous `use` callable: always APPENDS. (no class identity)
#   - `clear!`: drops all transforms AND settings (default_lang)
#   - `default_lang`: setter + getter; propagates into translate/speak
#     when the target_lang/voice option is omitted.
class BuilderTest < Test::Unit::TestCase
  Builder   = Reline::DialogTransform::Builder
  Translate = Reline::DialogTransform::Translate
  Speak     = Reline::DialogTransform::Speak

  def test_translate_called_twice_collapses_to_single_slot
    b = Builder.new
    b.translate target_lang: :ja
    b.translate target_lang: :en

    transforms = b.to_chain.transforms
    assert_equal 1, transforms.size
    assert_equal :en, transforms.first.target_lang
  end

  def test_use_called_twice_appends_both_in_order
    b = Builder.new
    p1 = ->(text, _ctx) { text.upcase }
    p2 = ->(text, _ctx) { text.reverse }
    b.use p1
    b.use p2

    assert_equal [p1, p2], b.to_chain.transforms
  end

  def test_clear_removes_all_transforms_and_settings
    b = Builder.new
    b.default_lang :ja
    b.translate
    b.speak
    b.use ->(t, _) { t }

    b.clear!

    assert_equal 0, b.to_chain.transforms.size
    assert_nil b.default_lang
  end

  def test_default_lang_setter_and_getter
    b = Builder.new
    assert_nil b.default_lang

    b.default_lang :ja
    assert_equal :ja, b.default_lang
  end

  def test_default_lang_propagates_to_translate_when_target_lang_omitted
    b = Builder.new
    b.default_lang :ja
    b.translate

    assert_equal :ja, b.to_chain.transforms.first.target_lang
  end

  def test_explicit_target_lang_overrides_default_lang
    b = Builder.new
    b.default_lang :ja
    b.translate target_lang: :en

    assert_equal :en, b.to_chain.transforms.first.target_lang
  end

  def test_speak_after_translate_both_present_in_order
    b = Builder.new
    b.translate target_lang: :ja
    b.speak voice: "ja-JP"

    assert_equal [Translate, Speak], b.to_chain.transforms.map(&:class)
  end

  def test_speak_replaced_but_position_preserved_relative_to_translate
    b = Builder.new
    b.translate target_lang: :ja
    b.speak voice: "ja-JP"
    b.speak voice: "en-US"

    transforms = b.to_chain.transforms
    assert_equal [Translate, Speak], transforms.map(&:class)
    assert_equal "en-US", transforms.last.voice
  end

  def test_anonymous_use_does_not_collide_with_named_slots
    b = Builder.new
    b.translate
    b.use ->(t, _) { t }
    b.use ->(t, _) { t }
    b.translate target_lang: :en

    transforms = b.to_chain.transforms
    # 1 translate slot (replaced) + 2 anonymous appends = 3 entries
    assert_equal 3, transforms.size
    assert_equal Translate, transforms.first.class
    assert_equal :en, transforms.first.target_lang
  end
end
