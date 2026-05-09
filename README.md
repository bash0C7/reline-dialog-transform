# reline-dialog-transform

Compose Reline dialog text transforms — `translate`, `speak`, and arbitrary user callables — applied to whatever appears in a Reline `:show_doc` (or other) dialog.

Built to extract the dialog-text translation pipeline out of [`apple_sdk_mac/irb`](https://github.com/bash0C7/rb-apple-sdk-mac/tree/main/irb), so the same hook can wrap RDoc, Apple SDK doc, or any other dialog source. **Status: pre-1.0 (`v0.0.1` development).**

## What it does

When you press TAB twice in IRB, Reline pops a doc dialog on the right side of the autocomplete popup. This gem hooks `Reline.add_dialog_proc(:show_doc, ...)` and routes every line of the dialog's `DialogRenderInfo#contents` through an ordered chain of transforms. Two transforms ship in the box:

- **`translate`** — runs each line through [`translation_mac-locale`](https://github.com/bash0C7/rb-translation-mac) (soft-loaded). Converts English RDoc / Apple SDK doc into your locale.
- **`speak`** — passthrough transform whose side effect is reading the line aloud via `AVSpeechSynthesizer` (soft-loaded through [`apple_sdk_mac`](https://github.com/bash0C7/rb-apple-sdk-mac)). Joke tier; opt-in via `RELINE_SPEAK=1`.

Anything callable can be added to the chain via `use ->(text, ctx) { ... }`.

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

## Quick start

The minimal `.irbrc`:

```ruby
require "reline/dialog_transform"
```

That alone discovers `~/.reline-dialog-transform.rb` (or `./.reline-dialog-transform.rb`) and wires up the dialog wrap. Configuration lives in the dotfile.

### Dotfile patterns

**Translate-only** (`~/.reline-dialog-transform.rb`):

```ruby
default_lang :ja
translate
```

**Speak-only**:

```ruby
speak voice: "ja-JP", rate: 0.5
```

(Speak is gated on `RELINE_SPEAK=1` by default, so you also need `export RELINE_SPEAK=1` in your shell.)

**Chain — translate then speak the translation**:

```ruby
default_lang :ja
translate
speak voice: "ja-JP"
```

**Chain — speak the original English then translate**:

```ruby
speak voice: "en-US"           # passthrough; speaks original
translate target_lang: :ja     # transforms text after speak
```

The order of method calls in the dotfile is the order of the chain. `speak` always passes the input text through unchanged so it's safe to layer either before or after `translate`.

### Custom transform via `use`

```ruby
use ->(text, _ctx) { text.gsub(/\e\[[0-9;]*m/, "") }   # ANSI strip
translate
```

The transform receives `(text, ctx)` where `ctx` is a Hash with optional `:source`, `:identifier`, `:framework`, `:klass`, `:kind`. Return the transformed (or unchanged) text.

## Project-local override

Drop a `.reline-dialog-transform.rb` in any working directory to override `~/`:

```
~/.reline-dialog-transform.rb         # personal default
~/dev/work-project/.reline-dialog-transform.rb   # this project's override
```

The two files merge with **OR semantics**: same-class transforms (`translate`, `speak`) get slot-replaced by project; anonymous `use` callables append; `default_lang` is overwritten last-wins. Project-only entries do NOT erase home entries — only `clear!` does that.

```ruby
# ./.reline-dialog-transform.rb
clear!                          # explicit reset; without this the home file's transforms stay
translate target_lang: :en      # this project keeps docs in English
```

## API

For programmatic use (no dotfile):

```ruby
require "reline/dialog_transform"

ENV["RELINE_DIALOG_TRANSFORM_AUTOLOAD"] = "off"   # (in your test setup, not .irbrc)
require "reline/dialog_transform"

Reline::DialogTransform.install!(default_lang: :ja) do |t|
  t.translate
  t.use ->(text, _ctx) { text.tr("\n", " ") }
  t.speak voice: "ja-JP" if ENV["RELINE_SPEAK"] == "1"
end
```

The block-arg form is recommended for in-code use because closures over outer state stay readable.

## Built-in transforms

### `translate` parameters

| Key | Default | Description |
|-----|---------|-------------|
| `target_lang:` | builder `default_lang` | BCP-47 string or symbol — the locale to translate to |
| `source_lang:` | nil (auto-detect) | source locale; usually fine to leave nil |
| `min_length:` | `2` | shorter lines bypass the translator |
| `skip_if:` | nil | proc(text, ctx) → bool to short-circuit per-line |
| `on_error:` | `:passthrough` | one of `:passthrough` / `:nil` / `:raise` |
| `translator:` | nil | inject a custom object responding to `#translate(text)` |

### `speak` parameters

| Key | Default | Description |
|-----|---------|-------------|
| `voice:` | builder `default_lang` | BCP-47 voice locale, e.g. `"ja-JP"` |
| `rate:` | `0.5` | speech rate, 0.0–1.0 |
| `pitch:` | `1.0` | pitch multiplier, 0.5–2.0 |
| `volume:` | `1.0` | 0.0–1.0 |
| `truncate_to:` | `200` | max chars actually spoken (text passthrough is unaffected) |
| `interrupt:` | `true` | stop the previous utterance before speaking |
| `async:` | `true` | use AVF's async dispatch (rarely overridden) |
| `enabled:` | `-> { ENV["RELINE_SPEAK"] == "1" }` | runtime gate — speech is opt-in by default |
| `speech_proc:` | nil | inject a callable for tests / non-Mac |

## Auto-load and ENV vars

| ENV var | Effect |
|---------|--------|
| `RELINE_DIALOG_TRANSFORM_AUTOLOAD=off` | suppress the require-time dotfile discovery + dialog wrap |
| `RELINE_DIALOG_TRANSFORM_DEBUG=1` | warn on Translate / Speak / chain-step exceptions instead of swallowing |
| `RELINE_SPEAK=1` | default-`enabled` proc returns true so `speak` actually speaks |

## Try it: `quick_start_example.rb`

The single canonical example. Lives at the gem root so you can run it the moment you `cd` in:

```sh
bundle exec ruby quick_start_example.rb
```

What it does:

1. Generates a temporary isolated HOME directory under `Dir.mktmpdir` and writes two files into it:
   - `.reline-dialog-transform.rb` — `default_lang :ja` + `translate` (and a commented-out `speak` line you can uncomment)
   - `.irbrc` — requires `apple_sdk_mac/irb` (when present) plus `reline/dialog_transform`
2. Prints copy-pasteable instructions for what to type at the irb prompt to see translation in action — e.g. `Apple::Foundation::URL.app` then TAB twice.
3. Pauses on `Press Enter to launch irb...` so you have time to read.
4. Spawns `bundle exec irb` with `HOME=` pointed at the scratch dir. Your real `~/.irbrc` is never touched.
5. After `exit`, cleans up the scratch dir **file by file** with `File.delete` (no `rm -rf`, ever) and finishes with `Dir.rmdir`. If anything unexpected was left behind, `rmdir` refuses and the directory is preserved with a warning so nothing arbitrary gets wiped.

When run from a bundle that has `apple_sdk_mac` + `translation_mac-locale` path-loaded (e.g. the `rb-apple-sdk-mac` development bundle), you get the full Apple SDK doc → Japanese demo. When run from this gem's own bundle, the wrap still installs and runs, the `translate` transform just passes through (no translator engine in scope) — useful for quickly sanity-checking a fresh `bundle install`.

> The other scripts under `test/` (`smoke_translate.rb`, `e2e_irb_pty.rb`) are verification tooling, not user examples. See [TUI verification](#tui-verification-phase-6) below.

## TUI verification (Phase 6)

Three layers of evidence under `test/`:

1. **Unit suite** — `test/rdoc_e2e_test.rb` exercises the wrap-and-thread-contents pipeline deterministically against fake `Reline::DialogRenderInfo` payloads.
2. **Cross-bundle smoke** — `test/smoke_translate.rb` runs the full translate pipeline against the real `TranslationMacHelper` when invoked from a bundle that has `translation_mac-locale` path-loaded. Not picked up by `rake test` (filename does not end in `_test.rb`); run by hand.
3. **Real PTY E2E** — `test/e2e_irb_pty.rb` spawns an actual `bundle exec irb` under PTY, types a partial Apple SDK identifier, sends TAB twice, captures the terminal byte stream and reports any Japanese codepoints found.

Run the PTY E2E:

```sh
mkdir -p /tmp/e2e_irb/home
cat > /tmp/e2e_irb/home/.reline-dialog-transform.rb <<'CONF'
default_lang :ja
translate
CONF
cat > /tmp/e2e_irb/home/.irbrc <<'IRBRC'
require "apple_sdk_mac"
require "apple_sdk_mac/irb"
AppleSDKMac::IRB.install!
IRBRC

cd ../rb-apple-sdk-mac   # bundle with apple_sdk_mac + reline-dialog-transform + translation_mac-locale
HOME=/tmp/e2e_irb/home \
  XDG_CACHE_HOME=$HOME/.cache \
  TERM=xterm-256color \
  bundle exec ruby ../reline-dialog-transform/test/e2e_irb_pty.rb \
    "Apple::Foundation::URL.app"
```

Expected output:

```
===== E2E summary =====
Target identifier: Apple::Foundation::URL.app
Captured bytes:    ~1900
Japanese codepoints: 100+ found, sample: パスコンポーネントをURLに追加すると新しいURLが返されます…
=======================
```

For a manual hands-on verification (no PTY automation), use `quick_start_example.rb` and TAB twice on the suggested identifier.

## Architecture

```
lib/reline/dialog_transform.rb         # public install! / load!
lib/reline/dialog_transform/builder.rb # DSL builder, slot replacement
lib/reline/dialog_transform/chain.rb   # ordered transform runner
lib/reline/dialog_transform/loader.rb  # dotfile discovery + DSL eval
lib/reline/dialog_transform/translate.rb
lib/reline/dialog_transform/speak.rb
```

See `docs/superpowers/specs/2026-05-08-reline-dialog-transform-design.md` for the full design rationale (7 confirmed decisions + 6-phase TDD plan).

## License

MIT — see `LICENSE.txt`.
