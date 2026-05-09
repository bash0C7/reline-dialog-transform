#!/usr/bin/env ruby
# frozen_string_literal: true
# Probe: instrument show_doc wrap, log every call. Identity chain so
# any redraw residue is purely from the wrap mechanism, not the chain.
# Logs: /tmp/reline_dialog_transform_diag.log

require "tmpdir"

LOG = "/tmp/reline_dialog_transform_diag.log"
scratch = Dir.mktmpdir("reline-dialog-transform-probe-diag-")

chain_step = ENV.fetch("DT_DIAG_CHAIN", "identity")
chain_proc =
  case chain_step
  when "identity" then "->(text, _ctx) { text }"
  when "upcase"   then "->(text, _ctx) { text.upcase }"
  when "dup"      then "->(text, _ctx) { text.dup }"
  else "->(text, _ctx) { text }"
  end
File.write(File.join(scratch, ".reline-dialog-transform.rb"), <<~CONF)
  Reline::DialogTransform.install! do |t|
    t.use #{chain_proc}
  end
CONF

irbrc_body = <<~'IRBRC'
  require "reline/dialog_transform"
  module Reline
    module DialogTransform
      class << self
        alias_method :install_chain_orig, :install_chain
        def install_chain(chain, dialog:, reline:)
          existing_struct = reline.dialog_proc(dialog)
          existing_proc   = existing_struct ? existing_struct.dialog_proc : nil
          log_path = ENV.fetch("DT_DIAG_LOG")
          tracer = ->(label, info) {
            File.open(log_path, "a") do |f|
              if info.nil?
                f.puts "#{Time.now.strftime('%H:%M:%S.%L')} #{label} info=NIL"
              else
                cs = info.contents&.size
                w  = info.width
                px = info.pos&.x
                py = info.pos&.y
                cid = info.contents.object_id
                first = info.contents&.first&.to_s&.byteslice(0, 50)
                f.puts "#{Time.now.strftime('%H:%M:%S.%L')} #{label} sz=#{cs} w=#{w} pos=(#{px},#{py}) cid=#{cid} first=#{first.inspect}"
              end
            end
          }
          wrapped = -> {
            tracer.call("[before-inner]", nil)
            info = existing_proc ? instance_exec(&existing_proc) : nil
            tracer.call("[after-inner] ", info)
            if info.nil?
              next nil
            end
            ctx = {}
            info.contents = info.contents.map { |line| chain.call(line, ctx) }
            tracer.call("[after-chain] ", info)
            info
          }
          reline.add_dialog_proc(dialog, wrapped, Reline::DEFAULT_DIALOG_CONTEXT)
        end
      end
    end
  end
  Reline::DialogTransform.reinstall!
  $stderr.puts "[probe-diag] traced install_chain active."
IRBRC

File.write(File.join(scratch, ".irbrc"), irbrc_body)
File.write(LOG, "")

puts "============================================================"
puts "wrap diagnostic — chain=#{chain_step}, traced wrap"
puts "============================================================"
puts "  Try: 1.to + TAB + TAB + TAB"
puts "  Watch redraw. Then exit."
puts "  Log: #{LOG}"
puts "  In another terminal: tail -f #{LOG}"
puts "============================================================"
puts "  HOME: #{scratch}"
puts "============================================================"

env = {
  "HOME" => scratch,
  "TERM" => ENV["TERM"] || "xterm-256color",
  "DT_DIAG_LOG" => LOG,
}

Process.spawn(env, "bundle", "exec", "irb")
Process.wait

puts "[probe-diag] Log saved at #{LOG}"
puts "[probe-diag] cleaning up #{scratch}..."

%w[.reline-dialog-transform.rb .irbrc .irb_history .irb-cache .reline_history].each do |name|
  path = File.join(scratch, name)
  next unless File.exist?(path)
  File.delete(path)
end

begin
  Dir.rmdir(scratch)
rescue Errno::ENOTEMPTY
  warn "[probe-diag] WARN: #{scratch} not empty: #{Dir.children(scratch).inspect}"
end
