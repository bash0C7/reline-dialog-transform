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

  # ---- ANSI-escape guard ----
  #
  # Apple's Translation framework strips C0 control bytes (0x1b ESC)
  # from input. When Reline hands us a syntax-highlighted line like
  # "\e[1;32mString.upcase\e[m", translating it returns
  # "[1;32mString.upcase[m" — the ANSI codes are now naked literals
  # that render as "[1;32m..." in the dialog. Skip translation for
  # any text that contains an ESC byte to preserve Reline's styling.

  def test_call_skips_text_containing_ansi_escape
    fake = FakeTranslator.new
    t = Translate.new(target_lang: :ja, translator: fake)
    styled = "\e[1;32mString.upcase\e[m"
    assert_equal styled, t.call(styled, {})
    assert_empty fake.calls
  end

  def test_call_skips_text_with_ansi_embedded_mid_line
    fake = FakeTranslator.new
    t = Translate.new(target_lang: :ja, translator: fake)
    styled = "Returns \e[1;32mString.upcase\e[m method"
    assert_equal styled, t.call(styled, {})
    assert_empty fake.calls
  end

  def test_call_translates_plain_text_without_ansi
    # Sanity: ANSI guard must not regress the normal path.
    fake = FakeTranslator.new
    t = Translate.new(target_lang: :ja, translator: fake)
    assert_equal "T(Returns the receiver)", t.call("Returns the receiver", {})
    assert_equal ["Returns the receiver"], fake.calls
  end

  # ---- newline stripping ----
  #
  # Apple Translation framework appends a trailing "\n" to every result
  # (verified at /tmp/translate_probe.rb: "...Returns the receiver
  # unchanged." → "...Returns the receiver unchanged.\n"). When that
  # newline lands inside a Reline dialog row, the terminal advances
  # the cursor mid-render and Reline's internal cursor_y tracking
  # desyncs — old dialog frames bleed into subsequent renders, the
  # autocomplete column gets partially overwritten. Translate must
  # strip newlines from the translator output so each line stays one
  # dialog row.

  def test_translate_strips_trailing_newline_from_translator_output
    fake = FakeTranslator.new(stub: { "Hello, world." => "こんにちは、世界。\n" })
    t = Translate.new(target_lang: :ja, translator: fake)
    assert_equal "こんにちは、世界。", t.call("Hello, world.", {})
  end

  def test_translate_strips_embedded_newlines_from_translator_output
    fake = FakeTranslator.new(stub: { "abc def" => "alpha\nbeta\ngamma" })
    t = Translate.new(target_lang: :ja, translator: fake)
    refute_includes t.call("abc def", {}), "\n"
  end

  def test_translate_strips_carriage_returns_too
    fake = FakeTranslator.new(stub: { "abc def" => "x\ry\r\nz" })
    t = Translate.new(target_lang: :ja, translator: fake)
    refute_includes t.call("abc def", {}), "\r"
  end

  # ---- SKIP_RDOC_NON_PROSE preset ----
  #
  # IRB show_doc dialog content includes mixed line types. Translating
  # everything is slow (Apple Translation: ~2s per line, no batch API)
  # AND quality-poor on code (method signatures get capitalized weirdly,
  # code examples lose semantics). This preset skip_if proc keeps the
  # fast path for clearly non-prose lines so only paragraphs translate.

  def skip
    Reline::DialogTransform::Translate::SKIP_RDOC_NON_PROSE
  end

  def assert_skipped(line)
    assert_true skip.call(line, {}), "expected SKIP_RDOC_NON_PROSE to skip #{line.inspect}"
  end

  def assert_translated(line)
    assert_false skip.call(line, {}), "expected SKIP_RDOC_NON_PROSE to translate #{line.inspect}"
  end

  def test_smart_skip_skips_irb_alt_d_header
    assert_skipped "Press Alt+d to read the full doc"
  end

  def test_smart_skip_skips_method_signature
    assert_skipped "upcase(mapping = :ascii) -> new_str"
  end

  def test_smart_skip_skips_method_signature_no_args
    assert_skipped "size -> integer"
  end

  def test_smart_skip_skips_indented_code_example
    assert_skipped %q(  "hEllO".upcase  #=> "HELLO")
  end

  def test_smart_skip_skips_rdoc_heading_rule
    assert_skipped "=== upcase"
  end

  def test_smart_skip_translates_prose_paragraph
    assert_translated "Returns a string containing the upcased characters in str."
  end

  def test_smart_skip_translates_attribution_line
    assert_translated "(from ruby core)"
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
