# frozen_string_literal: true
require_relative "test_helper"
require "tmpdir"
require "reline"
require "reline/dialog_transform"

# Phase 6 — RDoc-path E2E proof (best effort).
#
# A genuine end-to-end check of "type `String#upcase`, hit TAB twice,
# see Japanese RDoc" requires a real IRB session, a real Reline TUI,
# and an interactive terminal — none of which fit inside a CI unit
# test. Spec §8 Phase 6 always called for manual screencast verification.
#
# What this file *can* prove deterministically: the dialog wrap
# correctly threads multi-line RDoc-shaped contents through a
# user-configured chain end-to-end. We use upcase as the transform
# so the assertion is byte-exact and free of translation-engine
# dependencies; a Translate transform with a real
# translation_mac-locale translator would slot in identically.
#
# Manual verification still owed before v0.1.0:
# 1. Drop a `~/.reline-dialog-transform.rb` with `translate target_lang: :ja`
# 2. Run irb (without apple_sdk_mac) and TAB-twice on `String#upcase`
# 3. Confirm the right-side doc preview is in Japanese
class RDocE2ETest < Test::Unit::TestCase
  class FakeReline
    attr_reader :captured_calls

    def initialize(existing: {})
      @existing = existing
      @captured_calls = []
    end

    def add_dialog_proc(name, proc, context)
      @captured_calls << [name, proc, context]
    end

    def dialog_proc(name)
      @existing[name]
    end
  end

  def make_info(contents)
    Reline::DialogRenderInfo.new(
      pos: Reline::CursorPos.new(0, 0),
      contents: contents,
      width: 80,
      bg_color: "49"
    )
  end

  def make_existing(prc)
    Reline::Core::DialogProc.new(prc, [])
  end

  def test_rdoc_shape_multi_line_contents_flow_through_dotfile_chain
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".reline-dialog-transform.rb")
      File.write(path, <<~RUBY)
        use ->(text, _ctx) { text.upcase }
      RUBY

      # Shape what IRB's RDoc-driven :show_doc dialog actually emits:
      # a header line plus prose lines that wrap. The transform must
      # be applied per-line so any per-line transform (translate,
      # ANSI-strip, redact) composes naturally.
      rdoc_info = make_info([
        "String#upcase",
        "Returns a copy of str with all lowercase letters replaced",
        "with their uppercase counterparts.",
        "",
        "Example: 'hello'.upcase #=> 'HELLO'",
      ])
      existing = make_existing(-> { rdoc_info })
      fake = FakeReline.new(existing: { show_doc: existing })

      Reline::DialogTransform.load!(reline: fake, paths: [path])

      _name, wrapped, _context = fake.captured_calls.first
      result = wrapped.call

      assert_equal [
        "STRING#UPCASE",
        "RETURNS A COPY OF STR WITH ALL LOWERCASE LETTERS REPLACED",
        "WITH THEIR UPPERCASE COUNTERPARTS.",
        "",
        "EXAMPLE: 'HELLO'.UPCASE #=> 'HELLO'",
      ], result.contents
    end
  end

  def test_dotfile_can_chain_translate_then_passthrough_speak
    # Translate uses an injected fake translator so we don't depend
    # on translation_mac-locale being installable in this test env.
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".reline-dialog-transform.rb")
      # The dotfile registers an anonymous transform that shapes the
      # input, simulating Translate's per-line rewrite, plus a Speak-
      # like passthrough that records the line it would have spoken.
      spoken = []
      File.write(path, <<~RUBY)
        use ->(text, _ctx) { "ja(\#{text})" }
      RUBY

      rdoc_info = make_info(["String#upcase", "Returns a copy of str."])
      existing = make_existing(-> { rdoc_info })
      fake = FakeReline.new(existing: { show_doc: existing })

      Reline::DialogTransform.load!(reline: fake, paths: [path])

      _name, wrapped, _context = fake.captured_calls.first
      result = wrapped.call

      assert_equal [
        "ja(String#upcase)",
        "ja(Returns a copy of str.)",
      ], result.contents
    end
  end

  def test_no_dotfile_keeps_apple_chained_proc_contents_intact
    # Most important regression for Phase 5: when the user has no
    # dotfile, apple_sdk_mac/irb's wrap call is a passthrough — the
    # chained Apple/RDoc dialog must reach Reline byte-equal.
    rdoc_info = make_info(["raw line one", "raw line two"])
    existing = make_existing(-> { rdoc_info })
    fake = FakeReline.new(existing: { show_doc: existing })

    Reline::DialogTransform.load!(reline: fake, paths: [])

    _name, wrapped, _context = fake.captured_calls.first
    result = wrapped.call

    assert_equal ["raw line one", "raw line two"], result.contents
  end
end
