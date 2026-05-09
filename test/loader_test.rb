# frozen_string_literal: true
require_relative "test_helper"
require "tmpdir"
require "reline/dialog_transform/loader"

# Spec: 2026-05-09-dsl-unification-design.md §2 D2.
# Loader.find returns the first existing dotfile path. Project (CWD)
# takes precedence over home; nil when neither exists. Loader does
# NOT load or evaluate the file — that responsibility is on
# Reline::DialogTransform.load!, which calls Kernel#load on the
# returned path.
class LoaderTest < Test::Unit::TestCase
  Loader = Reline::DialogTransform::Loader

  def with_tmpdirs
    Dir.mktmpdir("home") do |home|
      Dir.mktmpdir("project") do |project|
        yield home, project
      end
    end
  end

  def write_config(dir, body = "")
    path = File.join(dir, ".reline-dialog-transform.rb")
    File.write(path, body)
    path
  end

  def test_find_prefers_project_when_both_exist
    with_tmpdirs do |h, p|
      write_config(h)
      proj = write_config(p)

      assert_equal proj, Loader.find(home_dir: h, project_dir: p)
    end
  end

  def test_find_falls_back_to_home_when_project_missing
    with_tmpdirs do |h, p|
      home = write_config(h)

      assert_equal home, Loader.find(home_dir: h, project_dir: p)
    end
  end

  def test_find_returns_project_when_home_missing
    with_tmpdirs do |h, p|
      proj = write_config(p)

      assert_equal proj, Loader.find(home_dir: h, project_dir: p)
    end
  end

  def test_find_returns_nil_when_neither_exists
    with_tmpdirs do |h, p|
      assert_nil Loader.find(home_dir: h, project_dir: p)
    end
  end

  def test_find_handles_home_equals_project_dir
    with_tmpdirs do |h, _p|
      same = write_config(h)
      # User running irb from $HOME — should still resolve to the one file.
      assert_equal same, Loader.find(home_dir: h, project_dir: h)
    end
  end
end
