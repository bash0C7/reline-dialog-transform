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

## Manual TUI verification (Phase 6)

The unit suite exercises the wrap and contents threading deterministically (see `test/rdoc_e2e_test.rb`), but a real TUI demo of "TAB twice on `String#upcase` shows Japanese RDoc" must be done by hand. Reproducer:

```sh
# 1. drop a dotfile
cat > ~/.reline-dialog-transform.rb <<'CONF'
default_lang :ja
translate
CONF

# 2. ensure the .irbrc loads the gem
echo 'require "reline/dialog_transform"' >> ~/.irbrc

# 3. start irb
bundle exec irb

# 4. type `String#upcase` (don't press Enter)
# 5. press TAB twice
# 6. observe the right-side popup — the RDoc preview should be Japanese
```

For Apple SDK doc translation specifically, install [`apple_sdk_mac-irb`](https://github.com/bash0C7/rb-apple-sdk-mac/tree/main/irb) too and TAB-twice on something like `Apple::Foundation::URL.appendingPathComponent`.

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
