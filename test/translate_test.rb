# frozen_string_literal: true
require_relative "test_helper"
require "reline/dialog_transform/translate"

# Phase 3 RED — Translate transform behavior, per spec §6.
#
# The transform composes:
#   - min_length skip (don't translate single tokens / short strings)
#   - skip_if proc (caller-supplied predicate)
#   - delegate to an injected translator (defaults to a soft-loaded
#     TranslationMac::Locale::Translator constructed from target_lang)
#   - on_error policy: :passthrough / :nil / :raise
#
# Cache is intentionally NOT a Translate concern — the upstream
# TranslationMac::Locale::Translator already memoizes per-text in a
# Mutex-guarded Hash, so duplicating that here would be wasteful.
class TranslateTest < Test::Unit::TestCase
  Translate = Reline::DialogTransform::Translate

  class FakeTranslator
    attr_reader :calls

    def initialize(stub: nil, raise_with: nil)
      @stub = stub
      @raise_with = raise_with
      @calls = []
    end

    def translate(text)
      @calls << text
      raise @raise_with if @raise_with
      @stub ? @stub.fetch(text, text) : "T(#{text})"
    end
  end

  # ---- min_length / skip_if ----

  def test_call_returns_original_when_under_min_length
    fake = FakeTranslator.new
    t = Translate.new(target_lang: :ja, min_length: 5, translator: fake)
    assert_equal "hi", t.call("hi", {})
    assert_empty fake.calls
  end

  def test_call_translates_when_at_or_above_min_length
    fake = FakeTranslator.new
    t = Translate.new(target_lang: :ja, min_length: 2, translator: fake)
    assert_equal "T(hello)", t.call("hello", {})
    assert_equal ["hello"], fake.calls
  end

  def test_skip_if_proc_short_circuits_before_translator
    fake = FakeTranslator.new
    skip = ->(text, _ctx) { text.start_with?("# ") }
    t = Translate.new(target_lang: :ja, skip_if: skip, translator: fake)
    assert_equal "# RUBY", t.call("# RUBY", {})
    assert_empty fake.calls
  end

  def test_skip_if_receives_text_and_ctx
    seen = []
    skip = ->(text, ctx) { seen << [text, ctx]; false }
    fake = FakeTranslator.new
    t = Translate.new(target_lang: :ja, skip_if: skip, translator: fake)
    ctx = { source: :rdoc }
    t.call("hello world", ctx)
    assert_equal [["hello world", ctx]], seen
  end

  # ---- on_error policy ----

  def test_on_error_passthrough_returns_original_text
    fake = FakeTranslator.new(raise_with: StandardError.new("nope"))
    t = Translate.new(target_lang: :ja, on_error: :passthrough, translator: fake)
    assert_equal "hello world", t.call("hello world", {})
  end

  def test_on_error_nil_returns_nil_for_failed_translation
    fake = FakeTranslator.new(raise_with: StandardError.new("nope"))
    t = Translate.new(target_lang: :ja, on_error: :nil, translator: fake)
    assert_nil t.call("hello world", {})
  end

  def test_on_error_raise_propagates
    fake = FakeTranslator.new(raise_with: StandardError.new("nope"))
    t = Translate.new(target_lang: :ja, on_error: :raise, translator: fake)
    assert_raise(StandardError) { t.call("hello world", {}) }
  end

  # ---- soft-load fallback ----

  def test_call_returns_original_when_no_translator_available
    # No injected translator and target_lang nil so the auto-build
    # path can't construct a default. Transform degrades to identity.
    t = Translate.new(target_lang: nil)
    assert_equal "hello world", t.call("hello world", {})
  end

  # ---- nil / empty handling ----

  def test_call_returns_nil_for_nil_text
    fake = FakeTranslator.new
    t = Translate.new(target_lang: :ja, translator: fake)
    assert_nil t.call(nil, {})
    assert_empty fake.calls
  end

  def test_call_returns_empty_for_empty_string
    fake = FakeTranslator.new
    t = Translate.new(target_lang: :ja, min_length: 1, translator: fake)
    assert_equal "", t.call("", {})
    assert_empty fake.calls
  end

  # ---- regression: Phase 1 attrs still expose target_lang / source_lang ----

  def test_phase1_target_lang_attr_still_readable
    t = Translate.new(target_lang: :ja)
    assert_equal :ja, t.target_lang
  end

  def test_phase1_source_lang_attr_still_readable
    t = Translate.new(target_lang: :ja, source_lang: :en)
    assert_equal :en, t.source_lang
  end
end
