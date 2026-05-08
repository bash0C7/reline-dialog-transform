# 2026-05-08 reline-dialog-transform Design

## 0. Status

**APPROVED** (2026-05-08) — 全 7 decision points 確定 (§4)。

会話発生元: `rb-apple-sdk-mac` の `apple_sdk_mac/irb` chained `:show_doc` proc に doc translation を実装した直後、 「翻訳ロジックは Apple SDK 非依存やから汎用 gem に切り出せるんちゃうか」 から始動。

## 1. Background

### 1.1 抽出元の現状

`rb-apple-sdk-mac/irb/lib/apple_sdk_mac/irb.rb` で以下のフロー確立済み:

- `Reline.add_dialog_proc(:show_doc, chained, Reline::DEFAULT_DIALOG_CONTEXT)` で IRB の doc dialog をフック
- `chained` proc は (1) Apple SDK の `DocDialog` で KB+LLM 由来 doc を render → 駄目なら (2) IRB 元来の `show_doc` proc にフォールバック
- Apple 側 doc には `doc_transform: ->(doc, ctx) { translator.translate(doc) }` を `DocResolver` / `LLMResolver` に注入して適用
- `translation_mac-locale` (sibling gem) が翻訳エンジン本体を提供

### 1.2 引き出すべき汎用パターン

「Reline の dialog proc を wrap し、 dialog の text 内容に変換 chain を噛ませる」 部分は Apple SDK と独立。 同じ仕組みを以下の用途にも使える:

- ANSI escape strip
- RDoc markup → plain text 整形
- 任意 LLM による要約・redaction
- 発話 (副作用のみの passthrough Transform)

### 1.3 残課題: RDoc 翻訳は未実証

現状の chained proc は **Apple ヒット時にだけ** `doc_transform` が走る。 IRB の元 `irb_proc` フォールバックは素のまま流してる (irb.rb:413)。 RDoc 由来 doc dialog の翻訳実証は本 gem で行う。

技術的見込みは立っている: IRB の show_doc proc は `Reline::DialogRenderInfo` を返す。 `.contents` が String 配列やから wrap して contents を transform して詰め直せばよい。 リスクは ANSI escape / RDoc::Markup section header の混入で、 これは Phase 6 で実証する。

## 2. Goals

- **Composable transform chain**: `translate` + `speak` + 任意 callable を順序付きで合成
- **REPL 非依存**: Reline 層の API を使うため IRB / Pry / 自作 REPL に通用
- **Dotfile DSL**: 環境変数では扱えん粒度の設定を Ruby DSL で記述
- **v0.1.0 で rb-apple-sdk-mac の `apple_sdk_mac/irb` 既存挙動を regression 無く差し替え可能にする**

## 3. Non-goals

- **翻訳エンジン本体の実装**: `translation_mac-locale` への依存で済ます
- **Reline 以外の補完 frontend サポート**: Pry が独自 dialog 名乗らせれば理屈上動くが、 動作保証は v0.1.0 では IRB のみ
- **発話エンジン本体の実装**: `apple_sdk_mac` 経由で `AVSpeechSynthesizer` を呼ぶ。 別プラットフォーム TTS は範囲外

## 4. Decisions

### Decision A — gem 名

**A1 (確定): `reline-dialog-transform`**
   - フック先は `Reline.add_dialog_proc` 。 IRB は use case の一個に過ぎず、 名前は実装層に揃える
   - `irb-` プレフィクスは scope を必要以上に狭く宣言してまうため不採用

### Decision B — 命名: transform vs translate

**B1 (確定): `transform`**
   - 翻訳は応用例の一つ、 ANSI strip / 要約 / 発話 / redaction も含む抽象が必要
   - 既存 `apple_sdk_mac/irb` の `doc_transform` パラメータ名と整合
   - `translate` 命名やと「翻訳しかせえへん gem」という契約に縛られる

### Decision C — DSL 形式

**C1 (確定): block-arg を primary、 instance_eval は dotfile 内のみ**

In code (`.irbrc` 等から呼ぶ場合):

```ruby
Reline::DialogTransform.install! do |t|
  t.translate target_lang: :ja
  t.speak     voice: "ja-JP"
end
```

In dotfile (`~/.reline-dialog-transform.rb` 等):

```ruby
translate target_lang: :ja
speak     voice: "ja-JP"
```

理由: in-code 呼び出しでは外部スコープ参照のため block-arg 安全、 dotfile は中身が DSL 専用やから instance_eval の bare method 形式が読みやすい。

### Decision D — Dotfile 探索順

**D1 (確定): `./.reline-dialog-transform.rb` (CWD) → `~/.reline-dialog-transform.rb` (home)**
   - 両方存在時は home → project の順で **同じ Builder に instance_eval** (§E の merge 対象)
   - 不在時は黙って no-op

### Decision E — Merge セマンティクス

**E1 (確定): OR 演算 (slot 置換 + append)**

| 要素 | 動作 |
|---|---|
| 同じ Transform クラス (`translate`, `speak` 等) | slot として **後勝ち** で置換、 元の挿入位置を保持 |
| 匿名 callable (`use ->(text, ctx) { ... }`) | 識別不可能やから常に **append** |
| Settings (`default_lang`) | 後勝ちで上書き |
| `clear!` | 蓄積した transforms / settings を全消し (project-only override したい時の opt-in) |

**動作例**:

home (`~/.reline-dialog-transform.rb`):

```ruby
default_lang :ja
translate
speak voice: "ja-JP"
```

project (`./.reline-dialog-transform.rb`):

```ruby
speak voice: "en-US"
use ->(t, c) { t.gsub(/\e\[[0-9;]*m/, "") }
```

最終 chain: `[translate (home 残存), speak (en-US), ANSI-strip]`

**継承**: project 側で素 Ruby の `load File.expand_path("~/.reline-dialog-transform.rb")` を呼ぶ手段あり (Builder への append が単純に積み上がる)。

### Decision F — Auto-load

**F1 (確定): `require "reline/dialog_transform"` で自動ロード、 ENV opt-out**
   - `~/.irbrc` は1行: `require "reline/dialog_transform"` のみ
   - 内部で `load!` を呼んで dotfile 探索 → Builder 構築 → `Reline.add_dialog_proc` 登録
   - opt-out: `ENV["RELINE_DIALOG_TRANSFORM_AUTOLOAD"] == "off"` (test spec_helper 用)
   - `Reline::DialogTransform.load!(paths: [...])` は public method として残す (明示制御 / dotfile path カスタム用)

### Decision G — Translate / Speak パラメータ仕様

#### G.1 Translate

| キー | 用途 | デフォルト |
|---|---|---|
| `target_lang:` | 訳出先 (BCP-47 文字列 or symbol) | builder の `default_lang` or ENV `RELINE_DIALOG_TRANSFORM_LANG` |
| `source_lang:` | 訳出元 | `nil` (auto-detect) |
| `cache:` | 結果メモ化 | `true` |
| `min_length:` | これ未満は素通し | `2` |
| `skip_if:` | `proc(text, ctx)` で除外条件 | `nil` |
| `on_error:` | `:passthrough` / `:nil` / `:raise` | `:passthrough` |

実装は `translation_mac-locale` (`TranslationMac::Locale::Translator`) への薄い wrapper。

#### G.2 Speak

| キー | 用途 | デフォルト |
|---|---|---|
| `voice:` | 声色ロケール (BCP-47) | builder の `default_lang` |
| `rate:` | 読み上げ速度 (0.0-1.0) | `0.5` |
| `pitch:` | 0.5-2.0 | `1.0` |
| `volume:` | 0.0-1.0 | `1.0` |
| `async:` | 非ブロック発火 | `true` |
| `truncate_to:` | N 文字以上はカット | `200` |
| `interrupt:` | 前の発話を停止して被せる | `true` |
| `enabled:` | `proc` で実行時 gate | `-> { ENV["RELINE_SPEAK"] == "1" }` |

`Speak` は **passthrough Transform** (text 改変無し、 副作用は発話のみ)。 chain での順序は「何の言語をしゃべるか」だけを変える。

実装は `apple_sdk_mac` (Apple framework bridge) 経由で `AVSpeechSynthesizer` の発話 API を呼ぶ。

## 5. Architecture

### 5.1 公開構造

```
reline-dialog-transform/
├── reline-dialog-transform.gemspec
├── lib/reline/dialog_transform.rb           # 公開 entry point + auto-load
├── lib/reline/dialog_transform/builder.rb   # DSL Builder (slot 置換ロジック)
├── lib/reline/dialog_transform/chain.rb     # Transform 配列を順次実行
├── lib/reline/dialog_transform/transform.rb # Transform 抽象
├── lib/reline/dialog_transform/loader.rb    # dotfile 探索
├── lib/reline/dialog_transform/translate.rb # soft-loads translation_mac-locale
├── lib/reline/dialog_transform/speak.rb     # soft-loads apple_sdk_mac
└── test/...
```

### 5.2 公開 API

```ruby
module Reline::DialogTransform
  def self.install!(dialog: :show_doc, default_lang: nil, &block); end
  def self.load!(dialog: :show_doc, paths: nil); end

  class Builder
    def translate(**opts); end
    def speak(**opts); end
    def use(callable); end
    def default_lang(lang = nil); end
    def clear!; end
    def to_chain; end
  end

  class Chain
    def initialize(transforms, error_isolation: true, max_input_length: nil); end
    def call(text, ctx); end
  end
end
```

### 5.3 Reline フック概要

`Reline::DialogRenderInfo` の `.contents` は String 配列。 既存 dialog (Apple SDK の DocDialog や IRB の RDoc dialog) の戻り値を wrap し、 `.contents` の各行に chain を適用して詰め直す。 これで dialog source 問わず同じ transform path を通せる。

### 5.4 ctx contract

汎用 gem やから ctx は **Hash 一本**:

```ruby
{
  source:     :apple_sdk,
  identifier: "Apple::Foundation::URL.appendingPathComponent",
  framework:  "Foundation",
  klass:      "URL",
  kind:       :class,
}
```

- `source:` は `:apple_sdk` / `:rdoc` / `:unknown`
- `kind:` は `:class` / `:module` / `:apple_root` / `nil`
- apple_sdk_mac/irb 側は `Context` Struct → Hash に変換して渡す (adapter 責務)
- RDoc fallback path は `{source: :rdoc, identifier: matched}` のみ詰める
- Hash にしたのは Struct より stable (将来 key 追加が破壊的変更にならん)

## 6. Translate transform

### 6.1 依存

- `translation_mac-locale` を soft-load
- `Translate.new` 時に gem 不在なら LoadError → warn → identity transform に成り下がる (gem 不在環境で gem 全体が落ちるのを避ける)

### 6.2 cache 戦略

- インスタンス内の Hash で text → translated メモ化
- spawn 時に Mutex 用意 (Reline は thread から触られる可能性)
- v0.1.0 では LRU 等は導入せず、 単純 Hash (irb session の生存期間と同じ。 メモリ問題報告が出てから対応)

### 6.3 source_lang detection

- `target_lang` のみ指定が default 経路、 `source_lang: nil` で auto-detect
- auto-detect は `translation_mac-locale` 側に委譲

## 7. Speak transform

### 7.1 依存

- `apple_sdk_mac` (Apple SDK bridge) 経由で AVFoundation を叩く
- `AVSpeechUtterance` 生成 → `voice` / `rate` / `pitchMultiplier` / `volume` 設定 → `AVSpeechSynthesizer` の発話 API に渡す
- 実 API call shape は Phase 4 で確認、 ここは方針

### 7.2 副作用設計

- text は **入力そのまま** 戻す (chain 上では passthrough)
- async fire-and-forget (AVSpeechSynthesizer は非同期動作がデフォルト、 spec で確認)
- truncate_to が効くのは **発話する文字列** のみ。 chain で次に渡す text は truncate せず原文のまま

### 7.3 disabled path

- `enabled` proc が false 返すと何もしない (発話せず passthrough)
- AVFoundation 不在環境 (CI 等) では init 時に capability probe して disabled に成り下がる

## 8. TDD Phase plan

各 phase は RED → GREEN → REFACTOR の 3 commit で進める (~/dev/src/CLAUDE.md の TDD コミット境界規律準拠)。

### Phase 1: Builder / Chain core
- RED: slot 置換セマンティクスの spec (translate を 2 回呼んで 1 個に潰れること、 use 2 回呼んで 2 個 append されること、 clear! で全消し)
- GREEN: Builder + Chain 実装
- REFACTOR: 必要なら

### Phase 2: Loader (dotfile 探索)
- RED: cwd / home の優先順、 home → project の順で同じ Builder に eval
- GREEN: Loader 実装
- REFACTOR

### Phase 3: Translate transform
- RED: translation_mac-locale を mock した状態で `min_length` 足切り、 cache hit / miss、 `on_error: :passthrough` の挙動 spec
- GREEN: Translate クラス実装
- REFACTOR

### Phase 4: Speak transform
- RED: passthrough であること (text 改変無し)、 `enabled: false` で副作用ゼロ、 truncate_to 適用、 mock した発話 API への引数 spec
- GREEN: Speak クラス実装
- REFACTOR

### Phase 5: rb-apple-sdk-mac/irb 差し替え
- RED: apple_sdk_mac-irb 既存 test suite が new gem 経由でも全部 pass する spec (regression test)
- GREEN: chained proc を `Reline::DialogTransform.install!` 経由に置換
- REFACTOR: 不要となった `LLMResolver` の `doc_transform` 引数等を整理

### Phase 6: RDoc 翻訳実証
- 素 irb (apple_sdk_mac 抜き) で `String#upcase` の RDoc dialog が `~/.reline-dialog-transform.rb` の `translate target_lang: :ja` 設定下で日本語化されることを E2E 確認
- 確認手段: 手動 + screencast、 spec として CI 自動化はしない (Reline / IRB の TUI が CI 不向き)
- 失敗時の調整候補:
  - ANSI escape strip を default `use` で前置
  - RDoc::Markup section header (`= Class Foo` 等) を skip_if で除外

## 9. v0.1.0 release-quality criteria

以下全部 green で v0.1.0 タグ:

1. Phase 1-4 の TDD spec が全部 pass (`bundle exec rake test`)
2. apple_sdk_mac-irb の既存 test suite が new gem 差し替え後も全部 pass (Phase 5)
3. README に dotfile sample + 3 パターン (translate-only / speak-only / chain) を全部記載
4. Phase 6 の RDoc 翻訳実証が成功 (素 irb で screenshot or screencast 1 本)
5. `RELINE_DIALOG_TRANSFORM_AUTOLOAD=off` で auto-load が抑止されることを spec で確認

## 10. Open items

なし (本 spec で全 decision 確定済み)。 Phase 進行中に発見された未決事項は別 spec として追加。

## 11. Cross-references

- 抽出元実装: `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/irb/lib/apple_sdk_mac/irb.rb`
- 翻訳エンジン: `~/dev/src/github.com/bash0C7/rb-translation-mac/locale/`
- 発話 API 経路: `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/`
- AVSpeechSynthesizer ref: https://developer.apple.com/documentation/avfoundation/speech-synthesis
