#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Probe: plain irb with NO reline-dialog-transform wrap at all.
# If redraw artifacts persist here, the bug is upstream in Reline 0.6.3
# (or IRB show_doc), not caused by our wrap. If clean here, our wrap
# does something that breaks Reline's dialog redraw tracking even
# without touching content.
#
# Usage: bundle exec ruby probe_plain_irb.rb

require "tmpdir"

scratch = Dir.mktmpdir("reline-dialog-transform-probe-plain-")

# .irbrc deliberately empty — no require, no install! call. We want
# absolute baseline: irb + reline as-is.
File.write(File.join(scratch, ".irbrc"), <<~IRBRC)
  $stderr.puts "[probe-plain] PLAIN IRB. No reline-dialog-transform wrap."
  $stderr.puts "[probe-plain] Try: 1.to + TAB, then TAB ↓ ↓ — watch for residue."
IRBRC

puts <<~BANNER
  ============================================================
  reline-dialog-transform redraw-artifact probe — PLAIN IRB
  ============================================================
  No reline-dialog-transform involvement at all. Just irb + reline.

  ── やってみる手順 ──
    1. プロンプトで `1.to` と打つ
    2. TAB を押す → 候補リスト + show_doc dialog が出る
    3. TAB を押して候補を順送り（カーソルは効かんって言うとったよな）
    4. 右側 doc dialog を見る：
        ・前候補のフレーム残骸が出るか？
        ・各候補で綺麗に redraw されるか？
    5. `exit` で終了

  ── 結果の解釈 ──
    残骸が出る  → Reline 0.6.3 の redraw bug（うちらの責ではない）
                  → upstream 報告 + workaround 検討
    綺麗に出る  → 我々の wrap が redraw を壊しとる
                  → install_chain の実装を見直し

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
puts "[probe-plain] cleaning up #{scratch}..."

%w[.irbrc .irb_history .irb-cache .reline_history].each do |name|
  path = File.join(scratch, name)
  next unless File.exist?(path)
  File.delete(path)
  puts "[probe-plain]   removed #{name}"
end

begin
  Dir.rmdir(scratch)
  puts "[probe-plain]   rmdir #{scratch}"
rescue Errno::ENOTEMPTY
  warn "[probe-plain] WARN: #{scratch} not empty after explicit cleanup"
  warn "[probe-plain]       leftover: #{Dir.children(scratch).inspect}"
end
