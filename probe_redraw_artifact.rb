#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Probe: isolate whether dialog redraw artifacts (residual frames from
# previous candidate's doc) come from translation widening visual
# columns past info.width, or from a Reline 0.6.3 redraw bug
# independent of content width.
#
# This dotfile uses ONLY String#upcase as the chain step. It does not
# translate. So every line keeps its ASCII byte count and its display
# column count. If artifacts persist with this config, the bug is in
# Reline's redraw and not in our wrap.
#
# Usage:
#   bundle exec ruby probe_redraw_artifact.rb
#
# Test steps inside the spawned irb:
#   1. Type:    1.to
#   2. Press:   TAB                (autocomplete opens, shows to_s etc)
#   3. Press:   ↓ (down arrow)     several times to cycle candidates
#   4. Watch:   does the doc dialog leave residual lines / boxes from
#               the previous candidate, or does each candidate redraw
#               cleanly?
#   5. Type:    exit
#
# Report back which of the two:
#   - "Artifacts STILL appear with upcase-only" → Reline bug, not ours
#   - "Clean redraw with upcase-only" → translation widens past
#                                       info.width; we own a fix

require "tmpdir"

CONFIG_FILES      = %w[.reline-dialog-transform.rb .irbrc].freeze
IRB_RUNTIME_FILES = %w[.irb_history .irb-cache .reline_history].freeze

scratch = Dir.mktmpdir("reline-dialog-transform-probe-")

File.write(File.join(scratch, ".reline-dialog-transform.rb"), <<~CONF)
  # Probe config: NO translate, ASCII-width-preserving upcase only.
  Reline::DialogTransform.install! do |t|
    t.use ->(text, _ctx) { text.upcase }
  end
CONF

File.write(File.join(scratch, ".irbrc"), <<~IRBRC)
  require "reline/dialog_transform"
  $stderr.puts "[probe] ready. upcase-only chain (no translation)."
  $stderr.puts "[probe] Try: 1.to + TAB, then ↓ ↓ ↓ — watch for redraw residue."
IRBRC

puts <<~BANNER
  ============================================================
  reline-dialog-transform redraw-artifact probe
  ============================================================
  Chain config (no translate, no width change):
      Reline::DialogTransform.install! do |t|
        t.use ->(text, _ctx) { text.upcase }
      end

  ── やってみる手順 ──
    1. プロンプトで `1.to` と打つ
    2. TAB を押す → 候補（to_s, to_int, to_r, to_f, ...）が出る
    3. ↓ を 3-5 回押す → 候補を順送り
    4. 右側 doc dialog を見る：
        ・前候補のフレームの残骸が出続けるか？
        ・それとも各候補で綺麗に redraw されるか？
    5. `exit` で終了

  ── 期待される結果の解釈 ──
    残骸が出る  → Reline 0.6.3 の redraw bug（うちらの問題ではない）
    綺麗に出る  → 翻訳による視覚幅膨張が原因 → うちらで fix する

  ============================================================
  HOME 隔離: #{scratch}
  ============================================================
BANNER

env = {
  "HOME" => scratch,
  "TERM" => ENV["TERM"] || "xterm-256color",
}

system(env, "bundle", "exec", "irb")

puts
puts "[probe] cleaning up #{scratch} (per-file rm + rmdir)..."

CONFIG_FILES.each do |name|
  path = File.join(scratch, name)
  begin
    File.delete(path)
    puts "[probe]   removed #{name}"
  rescue Errno::ENOENT
    puts "[probe]   missing (skip) #{name}"
  end
end

IRB_RUNTIME_FILES.each do |name|
  path = File.join(scratch, name)
  next unless File.exist?(path)
  File.delete(path)
  puts "[probe]   removed irb runtime file #{name}"
end

begin
  Dir.rmdir(scratch)
  puts "[probe]   rmdir #{scratch}"
rescue Errno::ENOTEMPTY
  warn "[probe] WARN: #{scratch} not empty after explicit cleanup; leaving in place"
  warn "[probe]       leftover entries: #{Dir.children(scratch).inspect}"
end
