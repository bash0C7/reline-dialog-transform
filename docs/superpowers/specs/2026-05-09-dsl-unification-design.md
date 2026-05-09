# 2026-05-09 DSL Unification & README Repositioning Design

## 0. Status

**APPROVED** (2026-05-09) — 2026-05-08 spec の Decision C / D / E / F に対する delta。 G は変更なし。 README リポジショニング (translate/speak を built-in 参考実装として位置づけ直し、 Installation を git: source 直参照に変更) も同梱。

## 1. Background

### 1.1 動機

2026-05-08 spec の Decision C は「in-code は block-arg、 dotfile は instance_eval bare method」 という二系統 DSL を確定していた。 Phase 1-6 完了後、 ユーザレビューで以下の判断:

- DSL は一本化したほうが学習コストが低い
- Loader の「instance_eval into Builder context」 という二重実装が保守上重い
- 同じ Builder へ home → project の OR-merge を効かせる Decision E のセマンティクスは仕様が複雑で利得が薄い
- README を「translate/speak ありき」 から「Reline dialog text を transform chain で加工する汎用基盤」 にリポジショニングしたい (translate/speak は built-in の参考実装、 ユースケースのひとつ)

### 1.2 影響範囲

本 delta は v0.0.1 開発中の段階で行う。 rubygems publish はしていないので外部互換性の縛りはない。 ただし sibling repo (`rb-apple-sdk-mac/irb`) は本 gem の `Reline::DialogTransform.load!` 経由で wrap しているため、 install! / load! の public シグネチャは互換維持する。

## 2. Decision delta

### C1 → C2: DSL 一本化

**C2 (確定)**: in-code も dotfile も `Reline::DialogTransform.install!(default_lang: :ja, dialog: :show_doc) do |t| ... end` の **block-arg 一本**。

```ruby
# in-code (.irbrc 等)
Reline::DialogTransform.install!(default_lang: :ja) do |t|
  t.translate
  t.speak voice: "ja-JP"
end

# dotfile (~/.reline-dialog-transform.rb)
Reline::DialogTransform.install!(default_lang: :ja) do |t|
  t.translate
  t.speak voice: "ja-JP"
end
```

dotfile は **素の Ruby ファイル**。 Loader は `load(path)` するだけ。 instance_eval は不採用。

### D1 → D2: dotfile 探索は片方のみ

**D2 (確定)**: `load!` は **CWD と home の片方しか load しない**。

- 探索順: `./.reline-dialog-transform.rb` (CWD) → `~/.reline-dialog-transform.rb` (home)
- 最初に見つかったほうのみ `load`。 残りは無視。
- 両方不在時は黙って no-op。

project dotfile が home の設定を継承したいときは project dotfile 内で明示:

```ruby
# ./.reline-dialog-transform.rb
load File.expand_path("~/.reline-dialog-transform.rb")  # 明示継承
Reline::DialogTransform.install!(default_lang: :en) do |t|
  t.translate target_lang: :en
end
```

### E1 → E2: last-wins

**E2 (確定)**: `install!` は呼ばれるたびに **新しい Builder を作り直し、 Reline proc を上書き登録**。

- 同 process 内で複数回呼ばれたら最後の `install!` が effective
- 直前の install! の transform 構成は捨てられる
- Reline.add_dialog_proc は同名で再呼び出しされると上書きされる前提 (Reline 0.6 の挙動)

これに伴う廃止項目:
- `Builder#clear!` 廃止 (last-wins で同効)
- `Builder#default_lang` DSL method 廃止 — `install!` の kwarg `default_lang:` に一本化
- 「同じ Builder への OR-merge」 「slot 置換」 「append 規則」 という Decision E の merge セマンティクス全体を廃止
- **Builder 内部の slot tracking / dedup も廃止** — Builder は単純な配列 push wrapper にする

#### Builder 内での同 transform 重複呼び

同一 install! ブロック内で `t.translate; t.translate` と書かれた場合の挙動:

```ruby
Reline::DialogTransform.install! do |t|
  t.translate target_lang: :ja
  t.translate target_lang: :en   # ← どうなる?
end
```

→ **そのまま append される** (chain は `[translate(:ja), translate(:en)]` の 2 個構成、 翻訳が 2 回走る)。 同じ transform を 2 回書くのは **ユーザ側の事故扱い**。 Builder は dedup しない (純配列 push のみ)。

これで Builder の実装は ~20 行の薄い wrapper に縮退。 「何が slot で何が append か」 という規則を覚える必要が完全に消える。

### F1 → F1': autoload 維持、 探索ロジックのみ更新

**F1' (確定)**: 維持。 ただし内部の `load!` 探索ロジックは D2 に従う (片方のみ load)。

- `require "reline/dialog_transform"` で `load!` を自動呼び出し
- `RELINE_DIALOG_TRANSFORM_AUTOLOAD=off` で opt-out
- `Reline::DialogTransform.load!(paths: [...])` は public method として残す

### G1: 変更なし

Translate / Speak のパラメータ仕様 (target_lang / voice / rate / etc.) は 2026-05-08 spec のまま。

## 3. 実装影響

### 3.1 `lib/reline/dialog_transform/builder.rb`

純配列 push wrapper まで縮退。 ~20 行。

- `clear!` メソッド削除
- `default_lang(lang = nil)` DSL method 削除
- **slot tracking / dedup ロジック削除** — `@slots = {}` 等の内部状態廃止
- `initialize(default_lang: nil)` で kwarg 受け取り、 子 transform に伝播
- `translate` / `speak` / `use` は `@transforms << ...` するだけ
- `to_chain` は `Chain.new(@transforms)` を返すだけ

実装イメージ:

```ruby
class Builder
  def initialize(default_lang: nil)
    @default_lang = default_lang
    @transforms = []
  end

  def translate(**opts)
    @transforms << Translate.new(target_lang: opts[:target_lang] || @default_lang, **opts)
  end

  def speak(**opts)
    @transforms << Speak.new(voice: opts[:voice] || @default_lang, **opts)
  end

  def use(callable)
    @transforms << callable
  end

  def to_chain
    Chain.new(@transforms)
  end
end
```

### 3.2 `lib/reline/dialog_transform.rb` (`install!` / `load!`)

```ruby
def self.install!(dialog: :show_doc, default_lang: nil, &block)
  builder = Builder.new(default_lang: default_lang)
  yield builder if block_given?
  chain = builder.to_chain
  Reline.add_dialog_proc(dialog, build_proc(chain), Reline::DEFAULT_DIALOG_CONTEXT)
  chain
end

def self.load!(dialog: :show_doc, paths: nil)
  candidates = paths || default_dotfile_paths
  target = candidates.find { |p| File.exist?(p) }
  return nil unless target
  load target
  target
end
```

- `install!` は dialog kwarg と default_lang kwarg のみ。 ブロックは Builder を yield。
- `load!` は片方しか load しない。 戻り値は load した path (テスト容易性のため)。

### 3.3 `lib/reline/dialog_transform/loader.rb`

大幅簡素化。 OR-merge / instance_eval / Builder 構築ロジックは全削除。 dotfile 探索 + `load` のみ。

実装上は `DialogTransform.load!` モジュールメソッドに統合する選択肢もある (Loader クラスを廃止)。 Phase D で判断。

### 3.4 既存テストの去就

| ファイル | 対応 |
|---|---|
| `test/builder_clear_test.rb` 等 clear! spec | 削除 |
| `test/builder_default_lang_test.rb` 等 DSL default_lang spec | 削除 (install! kwarg spec として書き直し) |
| `test/builder_test.rb` の slot 置換 spec | 削除。 「同名 transform 2 回呼びは append される (dedup しない)」 spec を新規追加 |
| `test/loader_or_merge_test.rb` 等 OR-merge spec | 削除 |
| `test/loader_test.rb` の dotfile 探索 spec | 「CWD あれば CWD のみ」 「home fallback」 「両方不在で no-op」 に書き直し |
| `test/install_test.rb` | last-wins spec を追加 (install! 2 回呼び → 後勝ち)、 既存 idempotent 想定 spec は削除 |
| `test/translate_test.rb`, `test/speak_test.rb`, `test/chain_test.rb`, `test/rdoc_e2e_test.rb` | 影響なし (transform 単体仕様は不変) |

### 3.5 `rb-apple-sdk-mac/irb` 側

`Reline::DialogTransform.load!` を呼ぶ前提は変わらないので互換維持。 ただし sibling リポジトリの dotfile 例を README に書いている場合は新 DSL 形式への更新を別途指示する (本リポジトリ範囲外)。

## 4. README 書き換え方針 (T1, T2, T3 統合)

**README には最新の状態のみ記載する。 過去言及・変更説明・transitional preamble (`Until v0.1.0...` 等) は不要。**

### 4.1 L5 サマリ削除 (T2)

```
Built to extract the dialog-text translation pipeline out of `apple_sdk_mac/irb`,
so the same hook can wrap RDoc, Apple SDK doc, or any other dialog source.
**Status: pre-1.0 (`v0.0.1` development).**
```

→ 削除。 出自情報・status 表記は不要。

### 4.2 Installation を git: source 直参照に書き換え (T1)

現状 (rubygems publish 想定):

```ruby
gem "reline-dialog-transform"
```

→ 以下に置換 (preamble なし、 最新の事実のみ):

```ruby
gem "reline-dialog-transform",
  git: "https://github.com/bash0C7/reline-dialog-transform"
```

soft-deps の sibling 併記:

```ruby
# Optional: enable the `translate` built-in transform
gem "translation_mac-locale",
  git:  "https://github.com/bash0C7/rb-translation-mac",
  glob: "locale/translation_mac-locale.gemspec"

# Optional: enable the `speak` built-in transform.
# rb-apple-sdk-mac's extconf.rb requires `swift_gem/mkmf` which is not
# resolvable from bundler's native-extension build subprocess, so install
# via ghq + path: instead of git: source:
#
#   ghq get https://github.com/bash0C7/rb-apple-sdk-mac
#   # then in your Gemfile:
gem "rb-apple-sdk-mac",
  path: "/path/to/ghq/root/github.com/bash0C7/rb-apple-sdk-mac"
```

### 4.3 トーンを「translate/speak = built-in 参考実装」 にリポジショニング (T3)

- "What it does" セクション (現 L7-14) のリード文を **「Reline `:show_doc` dialog の `DialogRenderInfo#contents` を transform chain で加工する汎用基盤」** に書き換え
- 「extract から始まった」 等の出自言及は一切なし
- translate / speak は **「Reference transforms (built-in examples)」** セクションに格下げ
- ユーザ拡張ポイント `t.use ->(text, ctx) { ... }` を冒頭近くに昇格

### 4.4 dotfile 例を新 DSL に置換

現状の README の instance_eval bare method 例を全部 install! block-arg 形式に書き換え:

```ruby
Reline::DialogTransform.install!(default_lang: :ja) do |t|
  t.translate
  t.speak voice: "ja-JP"
end
```

`clear!` 言及 (現 L99-105) は削除。 「project が home を継承したいときは `load File.expand_path(...)` を明示」 という運用法に差し替え。

### 4.5 `quick_start_example.rb` 内の dotfile 生成コードも新 DSL に追従 (T3 範囲)

`quick_start_example.rb:53-60` の `dotfile_body` および `:82-87` の README 風プロンプト出力部を新 DSL 形式に書き換える。

## 5. Phase plan (TDD コミット境界規律で進行)

各 phase は独立 commit。 RED / GREEN / REFACTOR は別 commit。

### Phase A: spec doc commit
- 本ドキュメントを `docs/superpowers/specs/2026-05-09-dsl-unification-design.md` として commit
- 単一 commit (`docs: …`)

### Phase B: Builder を純配列 push wrapper に縮退
- RED: 既存 clear! / default_lang DSL / slot 置換 spec を削除し、 「同名 transform 2 回呼びで append される」 spec を新規追加 (現状は slot 置換するので fail)
- GREEN: Builder の slot tracking / clear! / default_lang DSL method を全削除、 `initialize(default_lang:)` kwarg 追加、 `translate` / `speak` / `use` を単純 `<<` に
- REFACTOR: 必要なら (~20 行に収まる想定)

### Phase C: install! を毎回新 Builder + last-wins semantic に変更
- RED: `install!` を 2 回呼んで「後勝ち」 を期待する spec を書く (現状は累積なので fail)
- GREEN: install! を新 Builder 構築 + Reline proc 再登録に変更
- REFACTOR

### Phase D: Loader を「片方のみ load」 に簡素化
- RED: 「両方存在時に CWD のみ load される」 spec を書く (現状は両方 eval なので fail)
- GREEN: Loader を find-first + load に変更。 OR-merge / instance_eval logic 削除
- REFACTOR: Loader クラスを廃止して `DialogTransform.load!` モジュールメソッドに統合する選択肢を検討

### Phase E: README L5 サマリ削除 (T2)
- 単独 commit (`docs: …`)

### Phase F: README Installation を git: source 直参照に書き換え (T1)
- 単独 commit (`docs: …`)

### Phase G: README dotfile 例を新 DSL 形式 + translate/speak リポジショニング (T3 + T4 連動)
- 単独 commit (`docs: …`)
- "What it does" 書き換え、 dotfile 例全置換、 clear! 言及削除、 「Reference transforms」 セクション昇格

## 6. v0.1.0 release-quality criteria (更新)

2026-05-08 spec §9 から差し替え:

1. Phase B-D の TDD spec が全部 pass (`bundle exec rake test`)
2. apple_sdk_mac/irb の既存 test suite が new DSL 経由でも全部 pass (regression)
3. README に dotfile sample (新 DSL 形式) + 3 パターン (translate-only / speak-only / chain) を全部記載
4. Phase 6 の RDoc 翻訳実証 (素 irb で日本語 codepoint 検出) が新 DSL 環境でも成功
5. `RELINE_DIALOG_TRANSFORM_AUTOLOAD=off` で auto-load が抑止されることを spec で確認
6. README Installation セクションが git: source 直参照になっていること (T1 完了)
7. README L5 サマリが削除されていること (T2 完了)

## 7. Open items

なし。 Phase 進行中に発見された未決事項は別 spec として追加。

## 8. Cross-references

- 元 spec: `docs/superpowers/specs/2026-05-08-reline-dialog-transform-design.md`
- 抽出元実装: `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/irb/lib/apple_sdk_mac/irb.rb`
- 翻訳エンジン: `~/dev/src/github.com/bash0C7/rb-translation-mac/locale/`
- 発話 API 経路: `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/`
