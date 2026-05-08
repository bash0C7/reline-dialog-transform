# frozen_string_literal: true
require_relative "test_helper"
require "tmpdir"
require "reline/dialog_transform/loader"

# Phase 2 RED — dotfile discovery and instance_eval-into-Builder, per
# spec §4 D + §5.2.
#
# Rules:
#   - Discover priority: home first, project second (load order so the
#     project file's slot replacements override home's per §4 E)
#   - Both exist → [home, project]; one missing → just the other; neither → []
#   - Build instance_evals each path against the same Builder so bare DSL
#     methods (translate, speak, default_lang) work in the dotfile body
class LoaderTest < Test::Unit::TestCase
  Loader  = Reline::DialogTransform::Loader
  Builder = Reline::DialogTransform::Builder

  def with_tmpdirs
    Dir.mktmpdir("home") do |home|
      Dir.mktmpdir("project") do |project|
        yield home, project
      end
    end
  end

  def write_config(dir, body)
    path = File.join(dir, ".reline-dialog-transform.rb")
    File.write(path, body)
    path
  end

  def test_discover_returns_home_then_project_when_both_exist
    with_tmpdirs do |h, p|
      home_path = write_config(h, "translate target_lang: :ja")
      proj_path = write_config(p, "speak voice: 'en-US'")

      assert_equal [home_path, proj_path],
                   Loader.discover(home_dir: h, project_dir: p)
    end
  end

  def test_discover_returns_only_home_when_project_missing
    with_tmpdirs do |h, p|
      home_path = write_config(h, "translate target_lang: :ja")
      assert_equal [home_path], Loader.discover(home_dir: h, project_dir: p)
    end
  end

  def test_discover_returns_only_project_when_home_missing
    with_tmpdirs do |h, p|
      proj_path = write_config(p, "translate target_lang: :ja")
      assert_equal [proj_path], Loader.discover(home_dir: h, project_dir: p)
    end
  end

  def test_discover_returns_empty_when_neither_exists
    with_tmpdirs do |h, p|
      assert_equal [], Loader.discover(home_dir: h, project_dir: p)
    end
  end

  def test_discover_dedupes_when_home_equals_project_dir
    with_tmpdirs do |h, _p|
      home_path = write_config(h, "translate")
      # User running irb from $HOME shouldn't double-load the same file.
      assert_equal [home_path], Loader.discover(home_dir: h, project_dir: h)
    end
  end

  def test_build_evaluates_paths_in_order_into_single_builder
    with_tmpdirs do |h, p|
      home_path = write_config(h, "translate target_lang: :ja")
      proj_path = write_config(p, "speak voice: 'en-US'")

      builder = Loader.build(paths: [home_path, proj_path])
      transforms = builder.to_chain.transforms

      assert_equal 2, transforms.size
      assert_kind_of Reline::DialogTransform::Translate, transforms[0]
      assert_kind_of Reline::DialogTransform::Speak, transforms[1]
    end
  end

  def test_build_or_merge_project_overrides_home_slot
    with_tmpdirs do |h, p|
      home_path = write_config(h, <<~RUBY)
        translate target_lang: :ja
        speak voice: "ja-JP"
      RUBY
      proj_path = write_config(p, 'speak voice: "en-US"')

      builder = Loader.build(paths: [home_path, proj_path])
      transforms = builder.to_chain.transforms

      assert_equal 2, transforms.size
      assert_equal :ja, transforms[0].target_lang
      assert_equal "en-US", transforms[1].voice
    end
  end

  def test_build_allows_default_lang_propagation_inside_dotfile
    with_tmpdirs do |h, _p|
      home_path = write_config(h, <<~RUBY)
        default_lang :ja
        translate
      RUBY

      builder = Loader.build(paths: [home_path])
      assert_equal :ja, builder.to_chain.transforms.first.target_lang
    end
  end

  def test_build_with_empty_paths_returns_fresh_builder
    builder = Loader.build(paths: [])
    assert_equal 0, builder.to_chain.transforms.size
    assert_nil builder.default_lang
  end

  def test_build_supports_use_callable_in_dotfile
    with_tmpdirs do |h, _p|
      home_path = write_config(h, <<~RUBY)
        use ->(text, _ctx) { text.upcase }
      RUBY

      builder = Loader.build(paths: [home_path])
      transforms = builder.to_chain.transforms
      assert_equal 1, transforms.size
      assert_equal "HELLO", transforms.first.call("hello", {})
    end
  end
end
