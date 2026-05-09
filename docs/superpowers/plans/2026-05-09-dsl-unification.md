# DSL Unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor `reline-dialog-transform` so that both in-code and dotfile configuration use a single `Reline::DialogTransform.install!(default_lang: …) do |t| … end` form. Drop the Loader OR-merge / instance_eval logic and the Builder slot tracking. Reposition the README so `translate` / `speak` are framed as built-in reference transforms (one of the use cases) rather than the headline feature, and rewrite the install path to reference the GitHub repo directly.

**Architecture:** Phase B reduces `Builder` to a pure array-push wrapper and updates `install!`'s constructor call to match. Phase C adds a regression test confirming `install!`'s last-wins behaviour (current implementation already creates a fresh `Builder` per call, so this is a sanity check). Phase D rewrites `Loader` from "discover both → instance_eval each into the same Builder" to "find the first existing path → `Kernel.load` it once, returning the path", and reduces `load!` accordingly. Phases E-G update `README.md` and `quick_start_example.rb` to match the new DSL while keeping the prose strictly current-state (no transitional preamble, no historical references).

**Tech Stack:** Ruby (CRuby 4.0+), test-unit 3.6, Reline 0.6, t-wada style TDD with separate RED / GREEN commits per phase.

**Spec source of truth:** `docs/superpowers/specs/2026-05-09-dsl-unification-design.md`

---

## Task 1 — Phase B RED: Rewrite `builder_test.rb` to the new spec

**Files:**
- Modify: `test/builder_test.rb` (full rewrite)

- [ ] **Step 1: Replace `test/builder_test.rb` with the new test set**

```ruby
# frozen_string_literal: true
require_relative "test_helper"
require "reline/dialog_transform/builder"

# Spec: 2026-05-09-dsl-unification-design.md §2 E2 + §3.1.
# Builder is a pure array-push wrapper. No slot tracking, no dedup,
# no clear!, no DSL default_lang method. default_lang flows through
# the constructor kwarg and is forwarded into translate/speak when
# their target_lang/voice option is omitted.
class BuilderTest < Test::Unit::TestCase
  Builder   = Reline::DialogTransform::Builder
  Translate = Reline::DialogTransform::Translate
  Speak     = Reline::DialogTransform::Speak

  def test_translate_called_twice_appends_both
    b = Builder.new
    b.translate target_lang: :ja
    b.translate target_lang: :en

    transforms = b.to_chain.transforms
    assert_equal 2, transforms.size
    assert_equal :ja, transforms[0].target_lang
    assert_equal :en, transforms[1].target_lang
  end

  def test_speak_called_twice_appends_both
    b = Builder.new
    b.speak voice: "ja-JP"
    b.speak voice: "en-US"

    transforms = b.to_chain.transforms
    assert_equal 2, transforms.size
    assert_equal "ja-JP", transforms[0].voice
    assert_equal "en-US", transforms[1].voice
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

  def test_default_lang_kwarg_propagates_into_speak
    b = Builder.new(default_lang: "ja-JP")
    b.speak

    assert_equal "ja-JP", b.to_chain.transforms.first.voice
  end

  def test_explicit_target_lang_overrides_default_lang
    b = Builder.new(default_lang: :ja)
    b.translate target_lang: :en

    assert_equal :en, b.to_chain.transforms.first.target_lang
  end

  def test_explicit_voice_overrides_default_lang
    b = Builder.new(default_lang: "ja-JP")
    b.speak voice: "en-US"

    assert_equal "en-US", b.to_chain.transforms.first.voice
  end

  def test_no_default_lang_translate_target_lang_stays_nil
    b = Builder.new
    b.translate

    assert_nil b.to_chain.transforms.first.target_lang
  end

  def test_translate_then_speak_preserves_call_order
    b = Builder.new
    b.translate target_lang: :ja
    b.speak voice: "ja-JP"

    assert_equal [Translate, Speak], b.to_chain.transforms.map(&:class)
  end

  def test_use_does_not_affect_other_transforms
    b = Builder.new
    callable = ->(t, _) { t }
    b.translate
    b.use callable
    b.speak

    transforms = b.to_chain.transforms
    assert_equal 3, transforms.size
    assert_kind_of Translate, transforms[0]
    assert_same   callable,    transforms[1]
    assert_kind_of Speak,      transforms[2]
  end
end
```

- [ ] **Step 2: Run the rewritten suite and confirm it fails**

Run: `bundle exec rake test TEST=test/builder_test.rb`

Expected: failures. Examples:
- `test_translate_called_twice_appends_both` fails (current Builder collapses translate to a single slot — `transforms.size` will be 1, not 2)
- `test_default_lang_kwarg_propagates_into_translate` fails (current `Builder.new` takes no kwargs — `ArgumentError: wrong number of arguments`)

- [ ] **Step 3: Commit RED**

```bash
git add test/builder_test.rb
git commit -m "$(cat <<'EOF'
test(builder): RED — pure-append spec, drop slot/clear!/default_lang DSL

Encode the 2026-05-09 spec: Builder.new takes default_lang: kwarg,
same-class transforms append (not slot-replace), clear! and DSL
default_lang are gone.
EOF
)"
```

---

## Task 2 — Phase B GREEN: Reduce `Builder` to a pure push wrapper, update `install!`'s constructor call

**Files:**
- Modify: `lib/reline/dialog_transform/builder.rb` (full rewrite)
- Modify: `lib/reline/dialog_transform.rb:18-22` (replace `Builder.new + builder.default_lang(...)` with `Builder.new(default_lang: …)`)

- [ ] **Step 1: Replace `lib/reline/dialog_transform/builder.rb`**

```ruby
# frozen_string_literal: true

require_relative "translate"
require_relative "speak"
require_relative "chain"

module Reline
  module DialogTransform
    # Pure array-push wrapper. translate/speak/use append the produced
    # transform to an internal list; to_chain returns a Chain over a
    # snapshot of that list. default_lang is captured at construction
    # time and forwarded into translate/speak when the corresponding
    # option (target_lang / voice) is omitted at the call site.
    class Builder
      def initialize(default_lang: nil)
        @default_lang = default_lang
        @transforms = []
      end

      def translate(**opts)
        opts[:target_lang] ||= @default_lang
        @transforms << Translate.new(**opts)
        self
      end

      def speak(**opts)
        opts[:voice] ||= @default_lang
        @transforms << Speak.new(**opts)
        self
      end

      def use(callable)
        @transforms << callable
        self
      end

      def to_chain
        Chain.new(@transforms.dup)
      end
    end
  end
end
```

- [ ] **Step 2: Update `install!` at `lib/reline/dialog_transform.rb:18-22`**

Locate the existing `install!` method:

```ruby
    def self.install!(dialog: :show_doc, default_lang: nil, reline: Reline)
      builder = Builder.new
      builder.default_lang(default_lang) if default_lang
      yield builder if block_given?
      install_chain(builder.to_chain, dialog: dialog, reline: reline)
    end
```

Replace its body so that the kwarg is passed through `Builder.new`:

```ruby
    def self.install!(dialog: :show_doc, default_lang: nil, reline: Reline)
      builder = Builder.new(default_lang: default_lang)
      yield builder if block_given?
      install_chain(builder.to_chain, dialog: dialog, reline: reline)
    end
```

- [ ] **Step 3: Run the Builder suite and confirm it now passes**

Run: `bundle exec rake test TEST=test/builder_test.rb`

Expected: all 10 tests pass.

- [ ] **Step 4: Run the full suite and observe the expected mid-refactor failures**

Run: `bundle exec rake test`

Expected:
- `BuilderTest` — pass (10/10)
- `InstallTest` — pass (the two `default_lang` paths still work; the load!-related tests are still operating on the unchanged Loader / load!)
- `LoaderTest` — failures: `test_build_or_merge_project_overrides_home_slot` and any test that asserts slot replacement after Builder rewrite. These will be cleaned up in Phase D.

This intermediate state is expected; the refactor commits across Phase B → D progressively, and full green returns at the end of Phase D.

- [ ] **Step 5: Commit GREEN**

```bash
git add lib/reline/dialog_transform/builder.rb lib/reline/dialog_transform.rb
git commit -m "$(cat <<'EOF'
feat(builder): GREEN — Builder shrinks to ~25-line array push wrapper

- Drop slot tracking / replace_or_append / clear! / DSL default_lang
- initialize(default_lang:) forwards to translate/speak as fallback
- install! switches to Builder.new(default_lang: …) (no DSL setter call)

LoaderTest's slot-replacement assertions intentionally fail at this
commit; they are cleaned up in Phase D.
EOF
)"
```

---

## Task 3 — Phase C: Regression test for `install!` per-call independence (last-wins)

**Files:**
- Modify: `test/install_test.rb` (append new test after `test_install_yields_builder_to_block`)

- [ ] **Step 1: Append the regression test**

Locate `test_install_yields_builder_to_block` in `test/install_test.rb` (around line 70-77). Right after it, before the `# ---- wrapped proc behavior ----` separator, insert:

```ruby
  def test_install_called_twice_each_call_creates_independent_registration
    fake = FakeReline.new(existing: { show_doc: make_existing(-> { make_info(["abc"]) }) })

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
```

- [ ] **Step 2: Run the install suite and confirm pass**

Run: `bundle exec rake test TEST=test/install_test.rb`

Expected: pass — the existing implementation already creates a fresh `Builder` per `install!` call, so each registered proc closes over its own Chain. In real Reline, `add_dialog_proc(:show_doc, …)` overwrites by name, so the second proc wins; here we assert that the two procs are independent and the second one reflects the second block's transforms.

- [ ] **Step 3: Commit**

```bash
git add test/install_test.rb
git commit -m "$(cat <<'EOF'
test(install): pin per-call independence (last-wins) as regression spec

install! must create a fresh Builder per call so successive invocations
do not leak transforms across one another. Real Reline's add_dialog_proc
overwrites by name, so the latest install! wins.
EOF
)"
```

---

## Task 4 — Phase D RED: Rewrite `loader_test.rb` to the find-first semantic, prune obsolete `install_test.rb` tests

**Files:**
- Modify: `test/loader_test.rb` (full rewrite)
- Modify: `test/install_test.rb` (delete one test, replace another)

- [ ] **Step 1: Replace `test/loader_test.rb`**

```ruby
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
```

- [ ] **Step 2: Update `test/install_test.rb` — delete the passthrough-wrap test**

Locate `test_load_with_no_dotfiles_still_registers_passthrough_wrap` (around lines 157-170 in the current file) and DELETE the entire method. New `load!` is a no-op when no dotfile exists; it must NOT register a wrap.

- [ ] **Step 3: Update `test/install_test.rb` — replace the explicit-paths test**

Locate `test_load_with_explicit_paths_builds_chain_from_dotfile` (around lines 139-155) and replace the entire method with:

```ruby
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

  def test_load_returns_nil_and_does_not_invoke_anything_when_no_path_exists
    Dir.mktmpdir do |dir|
      missing = File.join(dir, ".reline-dialog-transform.rb")

      result = Reline::DialogTransform.load!(paths: [missing])

      assert_nil result
    end
  end
```

- [ ] **Step 4: Run rake test and confirm the expected failures**

Run: `bundle exec rake test`

Expected (current code still has old Loader):
- `LoaderTest` — failures: `Loader.find` does not exist (`NoMethodError`), all 5 new tests fail
- `InstallTest::test_load_runs_the_dotfile_body_via_kernel_load` — fails: current `load!` calls `Loader.discover + Loader.build + install_chain`, not `Kernel#load` on the dotfile
- `InstallTest::test_load_returns_nil_and_does_not_invoke_anything_when_no_path_exists` — fails: current `load!` returns the install_chain result, not nil

- [ ] **Step 5: Commit RED**

```bash
git add test/loader_test.rb test/install_test.rb
git commit -m "$(cat <<'EOF'
test(loader,install): RED — find-first semantic, drop OR-merge & wrap-on-empty

- Loader.find returns a single path (or nil) instead of an array
- load! invokes Kernel#load on the discovered dotfile, no install_chain
- load! is a no-op (returns nil) when no dotfile exists
- Drop the passthrough-wrap-on-empty test (load! must not register
  anything when there is no dotfile)
EOF
)"
```

---

## Task 5 — Phase D GREEN: Simplify `Loader` and `load!`

**Files:**
- Modify: `lib/reline/dialog_transform/loader.rb` (full rewrite)
- Modify: `lib/reline/dialog_transform.rb:25-32` (rewrite `load!`)

- [ ] **Step 1: Replace `lib/reline/dialog_transform/loader.rb`**

```ruby
# frozen_string_literal: true

module Reline
  module DialogTransform
    # Resolves the dotfile path to load. Project (CWD) takes precedence
    # over home; nil when neither exists. The actual loading is done
    # by Reline::DialogTransform.load! via Kernel#load — Loader's only
    # job is path resolution, deliberately decoupled from execution so
    # tests can verify resolution without spawning Ruby code.
    module Loader
      CONFIG_BASENAME = ".reline-dialog-transform.rb"

      def self.find(home_dir: Dir.home, project_dir: Dir.pwd)
        candidates = [
          File.join(project_dir, CONFIG_BASENAME),
          File.join(home_dir,    CONFIG_BASENAME),
        ]
        candidates.uniq.find { |path| File.exist?(path) }
      end
    end
  end
end
```

- [ ] **Step 2: Replace `load!` in `lib/reline/dialog_transform.rb`**

Locate the existing `load!`:

```ruby
    def self.load!(dialog: :show_doc, paths: nil, reline: Reline)
      paths ||= Loader.discover
      builder = Loader.build(paths: paths)
      install_chain(builder.to_chain, dialog: dialog, reline: reline)
    end
```

Replace with:

```ruby
    # Discovers a dotfile (project takes precedence over home, single
    # match wins) and runs it via Kernel#load. The dotfile body is
    # plain Ruby and is expected to call Reline::DialogTransform.install!
    # itself. Returns the path that was loaded, or nil when none.
    def self.load!(paths: nil)
      target =
        if paths
          paths.find { |path| File.exist?(path) }
        else
          Loader.find
        end
      return nil unless target
      load target
      target
    end
```

- [ ] **Step 3: Update the autoload tail of `lib/reline/dialog_transform.rb`**

The autoload block currently calls `Reline::DialogTransform.load!` with no args, which still works after the signature change. Verify it still reads:

```ruby
if ENV["RELINE_DIALOG_TRANSFORM_AUTOLOAD"] != "off"
  begin
    Reline::DialogTransform.load!
  rescue StandardError => e
    warn "[reline-dialog-transform] auto-load failed: #{e.class}: #{e.message}"
  end
end
```

No change needed; just confirm.

- [ ] **Step 4: Run the full suite and confirm green**

Run: `bundle exec rake test`

Expected: all tests pass. If failures remain in `Translate` / `Speak` / `Chain` suites, they are unrelated to this plan and should be investigated separately.

- [ ] **Step 5: Commit GREEN**

```bash
git add lib/reline/dialog_transform/loader.rb lib/reline/dialog_transform.rb
git commit -m "$(cat <<'EOF'
feat(loader,load!): GREEN — find-first + Kernel#load, no install_chain

- Loader.find resolves a single path (project beats home, nil otherwise)
- load! does only Kernel#load on the resolved path; the dotfile body
  is plain Ruby and is expected to call install! itself
- OR-merge / instance_eval / Loader.build / Loader.discover are gone
EOF
)"
```

---

## Task 6 — Phase E: README — delete the L5 extract-from / status summary (T2)

**Files:**
- Modify: `README.md` (delete lines 5-6, including the surrounding blank lines as appropriate)

- [ ] **Step 1: Open `README.md` and locate the target line**

Current line 5 reads:

```
Built to extract the dialog-text translation pipeline out of [`apple_sdk_mac/irb`](https://github.com/bash0C7/rb-apple-sdk-mac/tree/main/irb), so the same hook can wrap RDoc, Apple SDK doc, or any other dialog source. **Status: pre-1.0 (`v0.0.1` development).**
```

- [ ] **Step 2: Delete the line and one of the surrounding blank lines**

After deletion, the top of the file should read:

```markdown
# reline-dialog-transform

Compose Reline dialog text transforms — `translate`, `speak`, and arbitrary user callables — applied to whatever appears in a Reline `:show_doc` (or other) dialog.

## What it does
```

(L7 "## What it does" follows the description paragraph directly with one blank line in between.)

- [ ] **Step 3: Sanity check**

Run: `head -10 README.md`

Confirm: no "Built to extract", no "Status: pre-1.0", no `v0.0.1`.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs(readme): drop extract-from-irb / pre-1.0 status preamble

README describes the current state only. Provenance and version-status
notes belong in commit history / CHANGELOG, not the README header.
EOF
)"
```

---

## Task 7 — Phase F: README — rewrite Installation to git: source direct refs (T1)

**Files:**
- Modify: `README.md` (the entire `## Installation` section, currently lines 16-35 prior to Task 6 deletion; line numbers shift by 1-2 after Task 6)

- [ ] **Step 1: Locate the Installation section and replace it**

The current section (post-Task-6) reads roughly:

```markdown
## Installation

Gemfile:

```ruby
gem "reline-dialog-transform"
```

Then:

```sh
bundle install
```

The `translation_mac-locale` and `apple_sdk_mac` deps are NOT pulled in automatically — only required when you actually instantiate the corresponding transform. Add them yourself if you want translation / speech:

```ruby
gem "translation_mac-locale"   # required for `translate`
gem "apple_sdk_mac"            # required for `speak`
```
```

Replace the section in full with:

````markdown
## Installation

```ruby
# Gemfile
gem "reline-dialog-transform",
  git: "https://github.com/bash0C7/reline-dialog-transform"
```

`translate` and `speak` reach for `translation_mac-locale` and `apple_sdk_mac` lazily — only when the transform is actually instantiated. Add the deps you want:

```ruby
# Optional: enables `t.translate`
gem "translation_mac-locale",
  git:  "https://github.com/bash0C7/rb-translation-mac",
  glob: "locale/translation_mac-locale.gemspec"

# Optional: enables `t.speak`. rb-apple-sdk-mac's extconf.rb requires
# `swift_gem/mkmf`, which is not resolvable from bundler's native-extension
# build subprocess, so install via ghq + path: rather than git: source.
#
#   ghq get https://github.com/bash0C7/rb-apple-sdk-mac
#
gem "rb-apple-sdk-mac",
  path: "/path/to/ghq/root/github.com/bash0C7/rb-apple-sdk-mac"
```

Then:

```sh
bundle install
```
````

- [ ] **Step 2: Sanity check**

Run: `grep -n "rubygems" README.md || true`

Confirm: no transitional language (`Until …`, `Once published`, etc.).

Run: `grep -n 'gem "reline-dialog-transform"' README.md`

Confirm only the new git: source form appears (no plain `gem "reline-dialog-transform"` line on its own).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs(readme): install from GitHub source, document sibling deps

reline-dialog-transform pulls from its GitHub repo. translate's and
speak's optional deps are listed alongside, with the rb-apple-sdk-mac
ghq + path: workaround called out (extconf.rb's swift_gem/mkmf require
fails under bundler's git: source install path).
EOF
)"
```

---

## Task 8 — Phase G: README dotfile examples + reposition translate/speak as built-in references; sync `quick_start_example.rb` (T3 + T4)

**Files:**
- Modify: `README.md` (multiple sections — see below)
- Modify: `quick_start_example.rb:53-58` (dotfile generation), `quick_start_example.rb:84-88` (banner text)

- [ ] **Step 1: Rewrite the "What it does" section**

Locate the existing section:

```markdown
## What it does

When you press TAB twice in IRB, Reline pops a doc dialog on the right side of the autocomplete popup. This gem hooks `Reline.add_dialog_proc(:show_doc, ...)` and routes every line of the dialog's `DialogRenderInfo#contents` through an ordered chain of transforms. Two transforms ship in the box:

- **`translate`** — runs each line through [`translation_mac-locale`](https://github.com/bash0C7/rb-translation-mac) (soft-loaded). Converts English RDoc / Apple SDK doc into your locale.
- **`speak`** — passthrough transform whose side effect is reading the line aloud via `AVSpeechSynthesizer` (soft-loaded through [`apple_sdk_mac`](https://github.com/bash0C7/rb-apple-sdk-mac)). Joke tier; opt-in via `RELINE_SPEAK=1`.

Anything callable can be added to the chain via `use ->(text, ctx) { ... }`.
```

Replace with:

```markdown
## What it does

This gem wraps `Reline.add_dialog_proc(:show_doc, ...)` and routes every line of the dialog's `DialogRenderInfo#contents` through an ordered chain of transforms. A transform is anything callable as `(text, ctx) → text`, so the chain is whatever you compose.

The simplest transform is a Proc you pass via `t.use`:

```ruby
Reline::DialogTransform.install! do |t|
  t.use ->(text, _ctx) { text.gsub(/\e\[[0-9;]*m/, "") }   # ANSI strip
end
```

`translate` and `speak` are reference transforms shipped with the gem — common doc-dialog use cases (translation, speech) packaged as built-in chain steps. They are optional and lazily soft-load their backends; ignore them if you only want custom callables.
```

- [ ] **Step 2: Rewrite the Quick start dotfile examples**

Locate the existing `### Dotfile patterns` block (the four examples currently use bare DSL: `default_lang :ja\ntranslate`, etc.). Replace from `### Dotfile patterns` through the line `... before or after \`translate\`.`:

````markdown
### Dotfile patterns

The dotfile is plain Ruby that calls `Reline::DialogTransform.install!`. Same DSL as in-code use.

**Translate-only** (`~/.reline-dialog-transform.rb`):

```ruby
Reline::DialogTransform.install!(default_lang: :ja) do |t|
  t.translate
end
```

**Speak-only**:

```ruby
Reline::DialogTransform.install! do |t|
  t.speak voice: "ja-JP", rate: 0.5
end
```

(Speak is gated on `RELINE_SPEAK=1` by default, so you also need `export RELINE_SPEAK=1` in your shell.)

**Chain — translate then speak the translation**:

```ruby
Reline::DialogTransform.install!(default_lang: :ja) do |t|
  t.translate
  t.speak voice: "ja-JP"
end
```

**Chain — speak the original English then translate**:

```ruby
Reline::DialogTransform.install! do |t|
  t.speak     voice: "en-US"
  t.translate target_lang: :ja
end
```

The order of method calls inside the block is the order of the chain. `speak` always passes the input text through unchanged so it's safe to layer either before or after `translate`.
````

- [ ] **Step 3: Replace the `### Custom transform via use` example**

Locate the block:

```markdown
### Custom transform via `use`

```ruby
use ->(text, _ctx) { text.gsub(/\e\[[0-9;]*m/, "") }   # ANSI strip
translate
```
```

Replace with:

````markdown
### Custom transform via `use`

```ruby
Reline::DialogTransform.install! do |t|
  t.use ->(text, _ctx) { text.gsub(/\e\[[0-9;]*m/, "") }   # ANSI strip
  t.translate target_lang: :ja
end
```
````

- [ ] **Step 4: Rewrite "Project-local override" section**

Locate the section starting `## Project-local override` and the `clear!` example. Replace the entire section from `## Project-local override` through the `clear!` code block with:

````markdown
## Project-local override

`load!` resolves a single dotfile: project (CWD) wins over home, only one is loaded. To layer a project-specific override on top of your home defaults, `load` the home file explicitly from the project file:

```ruby
# ./.reline-dialog-transform.rb
load File.expand_path("~/.reline-dialog-transform.rb")  # picks up your home defaults
Reline::DialogTransform.install!(default_lang: :en) do |t|
  t.translate target_lang: :en   # project wants English
end
```

Each `install!` call rebuilds the chain from scratch and re-registers the dialog proc with Reline (last call wins). To completely replace home settings, just don't `load` the home file.
````

- [ ] **Step 5: Rewrite the API section**

Locate the existing `## API` section and replace its body with:

````markdown
## API

```ruby
require "reline/dialog_transform"

Reline::DialogTransform.install!(default_lang: :ja) do |t|
  t.translate
  t.use ->(text, _ctx) { text.tr("\n", " ") }
  t.speak voice: "ja-JP" if ENV["RELINE_SPEAK"] == "1"
end
```

`install!` builds a `Builder`, yields it to your block, then registers a wrap proc with Reline. Each call creates a fresh `Builder` and overwrites the previous registration; there is no merge.

Public API:

| Method | Purpose |
|---|---|
| `Reline::DialogTransform.install!(dialog: :show_doc, default_lang: nil, &block)` | Build a chain from the block and register it. |
| `Reline::DialogTransform.load!(paths: nil)` | Find the dotfile (project ≻ home, single match) and `Kernel.load` it. The dotfile is expected to call `install!` itself. Returns the loaded path or nil. |
````

- [ ] **Step 6: Rename and reframe "Built-in transforms" → "Reference transforms"**

Locate `## Built-in transforms` and rename to:

```markdown
## Reference transforms

`translate` and `speak` ship with the gem as ready-to-use chain steps. Both lazily require their backend — the gem stays usable without those gems installed; you just can't call those transforms.

### `translate` parameters
```

The two parameter tables (translate / speak) are unchanged.

- [ ] **Step 7: Update `quick_start_example.rb` dotfile generation**

Locate `quick_start_example.rb` lines 53-58:

```ruby
dotfile_body = +<<~CONF
  # Auto-generated by quick_start_example.rb
  default_lang :ja
  translate
CONF
dotfile_body << "speak voice: \"ja-JP\", rate: 0.5\n" if with_speak
```

Replace with:

```ruby
dotfile_body = +<<~CONF
  # Auto-generated by quick_start_example.rb
  Reline::DialogTransform.install!(default_lang: :ja) do |t|
    t.translate
CONF
dotfile_body << "  t.speak voice: \"ja-JP\", rate: 0.5\n" if with_speak
dotfile_body << "end\n"
```

- [ ] **Step 8: Update `quick_start_example.rb` banner text**

Locate lines 84-88:

```ruby
  起動する irb 設定:
      default_lang :ja
      translate                # translation_mac-locale 経由
                               # (en → ja, Apple Translation framework)
  #{with_speak ? "      speak    voice: \"ja-JP\"  # AVSpeechSynthesizer (RELINE_SPEAK=1)" : "      # speak は --with-speak 指定時のみ追加"}
```

Replace with:

```ruby
  起動する irb 設定:
      Reline::DialogTransform.install!(default_lang: :ja) do |t|
        t.translate                # translation_mac-locale 経由
                                   # (en → ja, Apple Translation framework)
  #{with_speak ? "    t.speak voice: \"ja-JP\"  # AVSpeechSynthesizer (RELINE_SPEAK=1)" : "    # t.speak は --with-speak 指定時のみ追加"}
      end
```

- [ ] **Step 9: Sanity check the README**

Run: `grep -n "default_lang :ja$" README.md || true`
Confirm: no bare `default_lang :ja` line remaining (all examples are inside `install!` blocks now).

Run: `grep -n "clear!" README.md || true`
Confirm: zero matches.

Run: `grep -n "extract" README.md || true`
Confirm: zero matches.

- [ ] **Step 10: Commit**

```bash
git add README.md quick_start_example.rb
git commit -m "$(cat <<'EOF'
docs(readme,quick_start): unify DSL examples on install! block-arg

- Reframe translate/speak as reference transforms (one of the use cases)
- All dotfile examples switch to Reline::DialogTransform.install! form
- Replace clear!-based override pattern with explicit `load` inheritance
- Drop the "Two transforms ship in the box" framing
- quick_start_example.rb's generated dotfile and banner text follow suit
EOF
)"
```

---

## Task 9 — Final verification

**Files:** none modified

- [ ] **Step 1: Full test suite**

Run: `bundle exec rake test`

Expected: all tests pass. Note the count — should be in the same ballpark as before the refactor (a few tests removed, a few added; Builder went from 9 → 10 tests, Loader from 11 → 5 tests, Install from 11 → 11 tests after net delete-replace-add, so total drops by about 5).

- [ ] **Step 2: PTY E2E verification**

Run from a bundle that has `apple_sdk_mac` + `translation_mac-locale` available (the gem's own bundle satisfies this — `cd reline-dialog-transform`):

```sh
mkdir -p /tmp/e2e_irb_unification/home
cat > /tmp/e2e_irb_unification/home/.reline-dialog-transform.rb <<'CONF'
Reline::DialogTransform.install!(default_lang: :ja) do |t|
  t.translate
end
CONF
cat > /tmp/e2e_irb_unification/home/.irbrc <<'IRBRC'
require "apple_sdk_mac"
require "apple_sdk_mac/irb"
AppleSDKMac::IRB.install!
IRBRC

HOME=/tmp/e2e_irb_unification/home \
  XDG_CACHE_HOME=$HOME/.cache \
  TERM=xterm-256color \
  bundle exec ruby test/e2e_irb_pty.rb \
    "Apple::Foundation::URL.app"
```

Expected: the summary block reports 100+ Japanese codepoints captured, sample line includes hiragana / katakana characters.

- [ ] **Step 3: smoke_translate.rb cross-bundle smoke**

Run: `bundle exec ruby test/smoke_translate.rb`

Expected: outputs at least one `BEFORE:` / `AFTER:` pair where `AFTER:` contains Japanese text. Non-zero translation hits.

- [ ] **Step 4: Optional — `quick_start_example.rb` smoke (manual)**

Run: `bundle exec ruby quick_start_example.rb`

Type at the irb prompt: `Apple::Foundation::URL.app`, then TAB twice. Expect to see Japanese text in the doc dialog. Type `exit` to clean up.

- [ ] **Step 5: No commit**

This task is read-only verification. If any step fails, open a fresh task to investigate before declaring the plan complete.
