# reline-dialog-transform

Compose Reline dialog text transforms — `translate` and arbitrary user callables — applied to whatever appears in a Reline `:show_doc` (or other) dialog.

## What it does

This gem wraps `Reline.add_dialog_proc(:show_doc, ...)` and routes every line of the dialog's `DialogRenderInfo#contents` through an ordered chain of transforms. A transform is anything callable as `(text, ctx) → text`, so the chain is whatever you compose.

The simplest transform is a Proc you pass via `t.use`:

```ruby
Reline::DialogTransform.install! do |t|
  t.use ->(text, _ctx) { text.gsub(/\e\[[0-9;]*m/, "") }   # ANSI strip
end
```

`translate` is a reference transform shipped with the gem — a common doc-dialog use case (translation) packaged as a built-in chain step. It's optional and lazily soft-loads its backend; ignore it if you only want custom callables.

## Installation

```ruby
# Gemfile
gem "reline-dialog-transform",
  git: "https://github.com/bash0C7/reline-dialog-transform"
```

`translate` lazily requires its backend only when the transform is actually instantiated:

```ruby
# Optional: enables `t.translate`
gem "translation_mac-locale",
  git:  "https://github.com/bash0C7/rb-translation-mac",
  glob: "locale/translation_mac-locale.gemspec"
```

Then:

```sh
bundle install
```

## Quick start

The minimal `.irbrc`:

```ruby
require "reline/dialog_transform"
```

That alone:

1. Discovers `~/.reline-dialog-transform.rb` (or `./.reline-dialog-transform.rb`) and runs it via `Kernel.load`. The dotfile is plain Ruby that calls `Reline::DialogTransform.install!`.
2. Layers the wrap on top of IRB's `:show_doc` proc. IRB registers `:show_doc` later inside `IRB::RelineInputMethod#initialize` (after `.irbrc` finishes), which would normally overwrite anything wrapped during `.irbrc`. The library prepends that initializer and re-applies the last `install!` chain after `super`, so the wrap survives.

### Dotfile patterns

The dotfile is plain Ruby that calls `Reline::DialogTransform.install!`. Same DSL as in-code use.

**Translate-only** (`~/.reline-dialog-transform.rb`):

```ruby
Reline::DialogTransform.install!(default_lang: :ja) do |t|
  # SKIP_RDOC_NON_PROSE is recommended for IRB show_doc dialogs:
  # method signatures, code examples, the IRB header, and RDoc heading
  # rules bypass the translator. Apple Translation costs ~2s/line and
  # has no batch API, so cutting non-prose lines roughly thirds the
  # dialog wait.
  t.translate skip_if: Reline::DialogTransform::Translate::SKIP_RDOC_NON_PROSE
end
```

The order of method calls inside the block is the order of the chain.

### Custom transform via `use`

```ruby
Reline::DialogTransform.install! do |t|
  t.use ->(text, _ctx) { text.gsub(/\e\[[0-9;]*m/, "") }   # ANSI strip
  t.translate target_lang: :ja
end
```

The transform receives `(text, ctx)` where `ctx` is a Hash with optional `:source`, `:identifier`, `:framework`, `:klass`, `:kind`. Return the transformed (or unchanged) text.

> **Single-line invariant.** Each line of `info.contents` represents one row in the Reline dialog. Custom transforms must return single-line strings — embedded `\n` advances the terminal cursor mid-render and desyncs Reline's `cursor_y` tracking, leaving residual frames from the previous candidate's doc on screen and gaps in the autocomplete column. The built-in `translate` step strips CR/LF for you (Apple Translation framework appends `\n` to every result); custom `use` steps need to be careful not to emit newlines.

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

## API

```ruby
require "reline/dialog_transform"

Reline::DialogTransform.install!(default_lang: :ja) do |t|
  t.translate
  t.use ->(text, _ctx) { text.tr("\n", " ") }
end
```

`install!` builds a `Builder`, yields it to your block, then registers a wrap proc with Reline. Each call creates a fresh `Builder` and registers a new wrap on whatever is currently registered for `dialog:`. Calls layer (the wrap captures the current dialog proc as its inner step), so consecutive `install!` calls form a chain in registration order. The library uses this internally: the IRB hook calls `reinstall!` after IRB registers its own `:show_doc`, layering the user's chain on top of IRB's RDoc proc.

Public API:

| Method | Purpose |
|---|---|
| `Reline::DialogTransform.install!(dialog: :show_doc, default_lang: nil, &block)` | Build a chain from the block and register a wrap proc on `dialog:`. |
| `Reline::DialogTransform.load!(paths: nil)` | Find the dotfile (project ≻ home, single match) and `Kernel.load` it. The dotfile is expected to call `install!` itself. Returns the loaded path or nil. |
| `Reline::DialogTransform.reinstall!` | Re-apply the last `install!` chain on top of whatever proc is currently registered for that `dialog:`. Used by the IRB prepend hook; rarely called directly. |

## Reference transforms

`translate` ships with the gem as a ready-to-use chain step. It lazily requires its backend — the gem stays usable without `translation_mac-locale` installed; you just can't call `t.translate`.

### `translate` parameters

| Key | Default | Description |
|-----|---------|-------------|
| `target_lang:` | builder `default_lang` | BCP-47 string or symbol — the locale to translate to |
| `source_lang:` | nil (auto-detect) | source locale; usually fine to leave nil |
| `min_length:` | `2` | shorter lines bypass the translator |
| `skip_if:` | nil | proc(text, ctx) → bool to short-circuit per-line. Built-in preset: `Reline::DialogTransform::Translate::SKIP_RDOC_NON_PROSE` skips method signatures, code examples, the IRB show_doc header, and RDoc heading rules — recommended for IRB usage where Apple Translation's ~2s/line cost otherwise dominates the dialog wait |
| `on_error:` | `:passthrough` | one of `:passthrough` / `:nil` / `:raise` |
| `translator:` | nil | inject a custom object responding to `#translate(text)` |

`translate` strips CR/LF from the translator output before returning. Apple Translation framework appends `\n` to every result, and an embedded newline inside dialog content desyncs Reline's renderer (mid-row cursor advance → wrong y-position for subsequent rows → residue across candidate navigation).

## Auto-load and ENV vars

`require "reline/dialog_transform"` triggers two things at load time (both gated by `RELINE_DIALOG_TRANSFORM_AUTOLOAD`):

1. **Dotfile discovery** — `Reline::DialogTransform.load!` runs immediately, finding and `Kernel.load`'ing the first existing dotfile.
2. **IRB prepend** — when `IRB::RelineInputMethod` is loaded, the library prepends its `initialize` so `reinstall!` runs after `super`. This survives IRB registering its own `:show_doc` after `.irbrc` finishes.

| ENV var | Effect |
|---------|--------|
| `RELINE_DIALOG_TRANSFORM_AUTOLOAD=off` | suppress both the dotfile discovery and the IRB prepend |
| `RELINE_DIALOG_TRANSFORM_DEBUG=1` | warn on Translate / chain-step exceptions instead of swallowing |

## Try it: `quick_start_example.rb`

The gem's Gemfile path-loads `translation_mac-locale` (the sibling repo `rb-translation-mac/locale`) so `t.translate` actually translates. The demo drives IRB's stdlib RDoc dialog, which the wrap layers on top of automatically.

```sh
cd reline-dialog-transform
bundle install                                       # pulls translation_mac-locale via path:
bundle exec ruby quick_start_example.rb              # translate demo
```

> Prerequisites: the standard bash0C7 ghq layout under `~/dev/src/github.com/bash0C7/`. If `rb-translation-mac` is missing, `ghq get https://github.com/bash0C7/rb-translation-mac` and re-run `bundle install`.

What the script does:

1. Pre-flights `require "translation_mac/locale"`. Must succeed; otherwise it aborts with copy-pasteable fix-up instructions.
2. Generates a temporary isolated HOME under `Dir.mktmpdir` and writes two files into it:
   - `.reline-dialog-transform.rb` — calls `Reline::DialogTransform.install!(default_lang: :ja) { |t| t.translate skip_if: Reline::DialogTransform::Translate::SKIP_RDOC_NON_PROSE }`
   - `.irbrc` — single line: `require "reline/dialog_transform"`. Auto-load discovers the dotfile, runs it, and the IRB prepend hook layers the wrap on top of IRB's `:show_doc` after `RelineInputMethod#initialize`.
3. Prints copy-pasteable instructions: type `"hello".ups` at the prompt, then **TAB once**. IRB's autocomplete shows `upcase` / `upcase!` candidates; the doc preview that appears on the side renders in Japanese (translated by `translation_mac-locale`).
4. Spawns `bundle exec irb` with `HOME=` pointed at the scratch dir. Your real `~/.irbrc` is never touched.
5. After `exit`, cleans up the scratch dir **file by file** with `File.delete` (no `rm -rf`, ever) and finishes with `Dir.rmdir`. If anything unexpected was left behind, `rmdir` refuses and the directory is preserved with a warning.

> The scripts under `test/` (`smoke_translate.rb`, `e2e_irb_pty.rb`) are verification tooling, not user examples. See [TUI verification](#tui-verification) below.

## TUI verification

Three layers of evidence under `test/`:

1. **Unit suite** — `test/rdoc_e2e_test.rb` and `test/install_test.rb` exercise the wrap-and-thread-contents pipeline deterministically against fake `Reline::DialogRenderInfo` payloads (including the IRB-overwrite-then-`reinstall!` scenario).
2. **Cross-bundle smoke** — `test/smoke_translate.rb` runs the full translate pipeline against the real `TranslationMacHelper` when invoked from a bundle that has `translation_mac-locale` path-loaded. Not picked up by `rake test` (filename does not end in `_test.rb`); run by hand.
3. **Real PTY E2E** — `test/e2e_irb_pty.rb` spawns `bundle exec irb` under PTY against a scratch HOME, evaluates `Reline.dialog_proc(:show_doc).dialog_proc.source_location` at the prompt, and asserts the path points at `lib/reline/dialog_transform.rb` — proving the wrap survives IRB's `RelineInputMethod#initialize` overwrite.

Run the PTY E2E:

```sh
cd reline-dialog-transform
bundle exec ruby test/e2e_irb_pty.rb
```

Expected output:

```
===== E2E summary =====
Captured bytes:    ~900
Probe captured:    /Users/.../lib/reline/dialog_transform.rb:85
Wrap registered:   YES — :show_doc points at our wrap (lib/reline/dialog_transform.rb)
=======================
```

For hands-on verification, use `quick_start_example.rb` and TAB once on `"hello".ups` (or any stdlib method with RDoc).

## Architecture

```
lib/reline/dialog_transform.rb         # public install! / load!
lib/reline/dialog_transform/builder.rb # array-push DSL wrapper
lib/reline/dialog_transform/chain.rb   # ordered transform runner
lib/reline/dialog_transform/loader.rb  # dotfile path resolver
lib/reline/dialog_transform/translate.rb
```

## License

MIT — see `LICENSE.txt`.
