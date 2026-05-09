# frozen_string_literal: true
require_relative "test_helper"
require "tmpdir"
require "reline"
require "reline/dialog_transform"

# Phase 2.5 RED — public install! and load! API, per spec §5.2 / §5.3.
#
# Both APIs build a Builder, ask it to_chain, then register a wrap
# proc with Reline.add_dialog_proc that:
#   - Runs the existing dialog_proc registered for `dialog:` (if any)
#   - When that returns a DialogRenderInfo, applies chain to each line
#     of .contents and returns the mutated info
#   - When nothing existing, or existing returns nil, returns nil so
#     Reline shows no dialog
#
# Reline is injected (`reline:` kwarg) so the test stays hermetic.
class InstallTest < Test::Unit::TestCase
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
      width: 10,
      bg_color: "49"
    )
  end

  def make_existing(prc)
    Reline::Core::DialogProc.new(prc, [])
  end

  # ---- install! basics ----

  def test_install_registers_show_doc_dialog_by_default
    fake = FakeReline.new
    Reline::DialogTransform.install!(reline: fake) { |_t| }
    assert_equal :show_doc, fake.captured_calls.first[0]
  end

  def test_install_uses_custom_dialog_name
    fake = FakeReline.new
    Reline::DialogTransform.install!(dialog: :my_dialog, reline: fake) { |_t| }
    assert_equal :my_dialog, fake.captured_calls.first[0]
  end

  def test_install_passes_reline_default_dialog_context
    fake = FakeReline.new
    Reline::DialogTransform.install!(reline: fake) { |_t| }
    _name, _proc, ctx = fake.captured_calls.first
    assert_equal Reline::DEFAULT_DIALOG_CONTEXT, ctx
  end

  def test_install_yields_builder_to_block
    fake = FakeReline.new
    seen = nil
    Reline::DialogTransform.install!(reline: fake) do |t|
      seen = t
    end
    assert_kind_of Reline::DialogTransform::Builder, seen
  end

  def test_install_called_twice_each_call_creates_independent_registration
    fresh_info = -> {
      Reline::DialogRenderInfo.new(
        pos: Reline::CursorPos.new(0, 0),
        contents: ["abc"],
        width: 10,
        bg_color: "49"
      )
    }
    fake = FakeReline.new(existing: { show_doc: make_existing(fresh_info) })

    Reline::DialogTransform.install!(reline: fake) do |t|
      t.use ->(text, _) { text.upcase }
    end
    Reline::DialogTransform.install!(reline: fake) do |t|
      t.use ->(text, _) { text.reverse }
    end

    assert_equal 2, fake.captured_calls.size

    first_wrapped = fake.captured_calls[0][1]
    assert_equal ["ABC"], first_wrapped.call.contents

    second_wrapped = fake.captured_calls[1][1]
    assert_equal ["cba"], second_wrapped.call.contents
  end

  def test_default_lang_propagates_into_builder_for_translate_call
    fake = FakeReline.new
    captured_lang = nil
    Reline::DialogTransform.install!(reline: fake, default_lang: :ja) do |t|
      t.translate
      captured_lang = t.to_chain.transforms.first.target_lang
    end
    assert_equal :ja, captured_lang
  end

  # ---- wrapped proc behavior ----

  def test_wrapped_proc_returns_nil_when_no_existing_proc_registered
    fake = FakeReline.new
    Reline::DialogTransform.install!(reline: fake) do |t|
      t.use ->(text, _) { text.upcase }
    end
    _name, wrapped, _ctx = fake.captured_calls.first
    assert_nil wrapped.call
  end

  def test_wrapped_proc_returns_nil_when_existing_returns_nil
    existing = make_existing(-> { nil })
    fake = FakeReline.new(existing: { show_doc: existing })

    Reline::DialogTransform.install!(reline: fake) do |t|
      t.use ->(text, _) { text.upcase }
    end
    _name, wrapped, _ctx = fake.captured_calls.first
    assert_nil wrapped.call
  end

  def test_wrapped_proc_applies_chain_to_each_content_line
    info = make_info(["hello", "world"])
    existing = make_existing(-> { info })
    fake = FakeReline.new(existing: { show_doc: existing })

    Reline::DialogTransform.install!(reline: fake) do |t|
      t.use ->(text, _) { text.upcase }
    end
    _name, wrapped, _ctx = fake.captured_calls.first
    result = wrapped.call

    assert_equal ["HELLO", "WORLD"], result.contents
  end

  def test_wrapped_proc_with_empty_chain_passes_contents_through
    info = make_info(["unchanged"])
    existing = make_existing(-> { info })
    fake = FakeReline.new(existing: { show_doc: existing })

    Reline::DialogTransform.install!(reline: fake) { |_t| }
    _name, wrapped, _ctx = fake.captured_calls.first
    result = wrapped.call

    assert_equal ["unchanged"], result.contents
  end

  # ---- load! integration ----

  def test_load_runs_the_dotfile_body_via_kernel_load
    Dir.mktmpdir do |dir|
      dotfile  = File.join(dir, ".reline-dialog-transform.rb")
      flag     = File.join(dir, "executed.flag")
      File.write(dotfile, "File.write(#{flag.inspect}, 'yes')")

      result = Reline::DialogTransform.load!(paths: [dotfile])

      assert_equal dotfile, result
      assert(File.exist?(flag), "dotfile body should have run via Kernel#load")
      assert_equal "yes", File.read(flag)
    end
  end

  def test_load_returns_nil_when_no_path_exists
    Dir.mktmpdir do |dir|
      missing = File.join(dir, ".reline-dialog-transform.rb")

      result = Reline::DialogTransform.load!(paths: [missing])

      assert_nil result
    end
  end
end
