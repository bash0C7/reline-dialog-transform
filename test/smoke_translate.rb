#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Phase 6 best-effort screencast substitute: drives the full pipeline
# end-to-end against the real translator (when translation_mac-locale
# + TranslationMacHelper are reachable) and prints before/after of a
# multi-line RDoc-shaped dialog payload, so a human can eyeball that
# the wrap works without launching IRB and a real TTY.
#
# Run from the gem root (this gem's Gemfile has no translation_mac-
# locale, so the wrap will pass through unchanged):
#
#   bundle exec ruby test/smoke_translate.rb
#
# Run from a parent gem's bundle that DOES have translation_mac-locale
# (e.g. rb-apple-sdk-mac) to exercise real translation:
#
#   cd ../rb-apple-sdk-mac
#   bundle exec ruby ../reline-dialog-transform/test/smoke_translate.rb
#
# Override target locale via env:
#
#   RELINE_DIALOG_TRANSFORM_LANG=ja-JP bundle exec ruby test/smoke_translate.rb

ENV["RELINE_DIALOG_TRANSFORM_AUTOLOAD"] ||= "off"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "reline"
require "reline/dialog_transform"
require "tmpdir"

target_lang = ENV.fetch("RELINE_DIALOG_TRANSFORM_LANG", "ja-JP")

ORIGINAL_LINES = [
  "String#upcase",
  "Returns a copy of str with all lowercase letters replaced",
  "with their uppercase counterparts.",
  "",
  "Example: 'hello'.upcase  #=> 'HELLO'",
].freeze

# Mimic what IRB's :show_doc renders for `String#upcase`.
def fresh_info
  Reline::DialogRenderInfo.new(
    pos: Reline::CursorPos.new(0, 0),
    contents: ORIGINAL_LINES.dup,
    width: 80,
    bg_color: "49"
  )
end

# Stand-in for the chained Apple/RDoc proc apple_sdk_mac/irb registers
# in production. The wrap captures THIS via Reline.dialog_proc.
Reline.add_dialog_proc(:show_doc, ->(*) { fresh_info }, [])

puts "=== Before ==="
ORIGINAL_LINES.each { |l| puts "  #{l.empty? ? '(blank)' : l}" }
puts

Dir.mktmpdir do |dir|
  path = File.join(dir, ".reline-dialog-transform.rb")
  File.write(path, <<~CONF)
    Reline::DialogTransform.install!(default_lang: #{target_lang.to_sym.inspect}) do |t|
      t.translate
    end
  CONF

  Reline::DialogTransform.load!(paths: [path])
end

# Reline normally calls dialog procs via instance_exec; we mirror that
# without depending on Reline internals.
struct = Reline.dialog_proc(:show_doc)
result = Object.new.instance_exec(&struct.dialog_proc)

puts "=== After (target=#{target_lang}) ==="
if result.nil?
  puts "  (wrap returned nil — existing proc returned nil)"
else
  result.contents.each { |l| puts "  #{l.empty? ? '(blank)' : l}" }
end
puts

if result.nil?
  puts "[!] Wrap returned nil — pipeline misconfigured."
  exit 1
elsif result.contents == ORIGINAL_LINES
  puts "[!] Output equals input. Likely causes:"
  puts "    - translation_mac-locale gem is not in the active bundle"
  puts "    - TranslationMacHelper binary is missing or refused to run"
  puts "    - target_lang was unresolvable (C / POSIX / English)"
  puts "    - Translate.on_error hit :passthrough on the provider"
  puts "    Set RELINE_DIALOG_TRANSFORM_DEBUG=1 to see warnings."
  exit 2
else
  puts "[ok] Contents changed — full pipeline is wired and translating end-to-end."
  exit 0
end
