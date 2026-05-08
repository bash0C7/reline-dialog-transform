# frozen_string_literal: true
require_relative "test_helper"
require "reline/dialog_transform/speak"

# Phase 4 RED — Speak transform behavior, per spec §7.
#
# Speak is a passthrough transform: text in == text out. Its only
# job in the chain is the side effect of speaking the text aloud
# via an injected speech_proc (production = AVSpeechSynthesizer
# soft-loaded through apple_sdk_mac).
#
# Hardened defaults:
#   - enabled gating via proc (default reads ENV["RELINE_SPEAK"]) so
#     the side effect is opt-in — RDoc doc dialogs don't suddenly
#     start talking when a user enables this gem in IRB
#   - truncate_to caps the spoken text to a sane length so a
#     2000-char RDoc payload doesn't lock the speaker for 30+ seconds
#   - interrupt true so rapid TAB-cycling doesn't queue overlapping
#     speech utterances
#   - failure inside speech_proc must not break the passthrough; the
#     dialog text still flows through the chain
class SpeakTest < Test::Unit::TestCase
  Speak = Reline::DialogTransform::Speak

  def make_capture
    captured = []
    proc = ->(text, **opts) { captured << [text, opts] }
    [captured, proc]
  end

  # ---- passthrough + speech_proc dispatch ----

  def test_call_returns_text_unchanged_passthrough
    _captured, proc = make_capture
    s = Speak.new(voice: "ja-JP", speech_proc: proc, enabled: -> { true })
    assert_equal "hello", s.call("hello", {})
  end

  def test_call_invokes_speech_proc_with_text_and_voice
    captured, proc = make_capture
    s = Speak.new(voice: "ja-JP", speech_proc: proc, enabled: -> { true })
    s.call("hello", {})
    assert_equal 1, captured.size
    text, opts = captured.first
    assert_equal "hello", text
    assert_equal "ja-JP", opts[:voice]
  end

  def test_call_passes_rate_pitch_volume_to_speech_proc
    captured, proc = make_capture
    s = Speak.new(voice: "ja-JP", rate: 0.7, pitch: 1.2, volume: 0.8,
                  speech_proc: proc, enabled: -> { true })
    s.call("hello", {})
    _text, opts = captured.first
    assert_equal 0.7, opts[:rate]
    assert_equal 1.2, opts[:pitch]
    assert_equal 0.8, opts[:volume]
  end

  # ---- enabled gating ----

  def test_enabled_false_skips_speech_call_but_keeps_passthrough
    captured, proc = make_capture
    s = Speak.new(voice: "ja-JP", speech_proc: proc, enabled: -> { false })
    result = s.call("hello", {})
    assert_equal "hello", result
    assert_empty captured
  end

  def test_default_enabled_reads_reline_speak_env_var
    captured, proc = make_capture

    ENV.delete("RELINE_SPEAK")
    Speak.new(voice: "ja-JP", speech_proc: proc).call("hello", {})
    assert_empty captured

    ENV["RELINE_SPEAK"] = "1"
    Speak.new(voice: "ja-JP", speech_proc: proc).call("hello", {})
    assert_equal 1, captured.size
  ensure
    ENV.delete("RELINE_SPEAK")
  end

  # ---- truncate_to ----

  def test_truncate_to_limits_speech_text_but_not_chain_passthrough
    captured, proc = make_capture
    s = Speak.new(voice: "ja-JP", truncate_to: 5,
                  speech_proc: proc, enabled: -> { true })
    result = s.call("hello world this is long", {})
    assert_equal "hello world this is long", result
    text, _opts = captured.first
    assert_equal "hello", text
  end

  def test_truncate_to_no_op_when_text_shorter
    captured, proc = make_capture
    s = Speak.new(voice: "ja-JP", truncate_to: 100,
                  speech_proc: proc, enabled: -> { true })
    s.call("hi", {})
    assert_equal "hi", captured.first[0]
  end

  # ---- interrupt ----

  def test_interrupt_default_true_passes_to_speech_proc
    captured, proc = make_capture
    s = Speak.new(voice: "ja-JP", speech_proc: proc, enabled: -> { true })
    s.call("hello", {})
    assert_equal true, captured.first[1][:interrupt]
  end

  def test_interrupt_can_be_overridden_to_false
    captured, proc = make_capture
    s = Speak.new(voice: "ja-JP", interrupt: false,
                  speech_proc: proc, enabled: -> { true })
    s.call("hello", {})
    assert_equal false, captured.first[1][:interrupt]
  end

  # ---- error tolerance ----

  def test_speech_failure_does_not_break_passthrough
    bad = ->(*_) { raise "AVF error" }
    s = Speak.new(voice: "ja-JP", speech_proc: bad, enabled: -> { true })
    assert_equal "hello", s.call("hello", {})
  end

  # ---- nil / empty handling ----

  def test_call_returns_nil_for_nil_text
    captured, proc = make_capture
    s = Speak.new(voice: "ja-JP", speech_proc: proc, enabled: -> { true })
    assert_nil s.call(nil, {})
    assert_empty captured
  end

  def test_call_skips_empty_string
    captured, proc = make_capture
    s = Speak.new(voice: "ja-JP", speech_proc: proc, enabled: -> { true })
    s.call("", {})
    assert_empty captured
  end

  # ---- regression: Phase 1 voice attr ----

  def test_phase1_voice_attr_still_readable
    s = Speak.new(voice: "ja-JP")
    assert_equal "ja-JP", s.voice
  end
end
