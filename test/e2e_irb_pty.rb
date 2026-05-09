#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Self-contained PTY E2E driver — proves reline-dialog-transform's
# wrap survives IRB's RelineInputMethod#initialize. That initializer
# calls Reline.add_dialog_proc(:show_doc, ...), which would overwrite
# any :show_doc wrap registered during .irbrc evaluation. The library
# prepends a hook that calls reinstall! after super, so our wrap
# layers on top of IRB's. This driver verifies the prepend works in
# a real interactive irb session under a TTY (PTY) — the only place
# RelineInputMethod#initialize actually runs.
#
# Method: spawn `bundle exec irb` under PTY, wait for prompt, evaluate
# a Ruby expression that prints `Reline.dialog_proc(:show_doc).
# dialog_proc.source_location[0]`, parse the output and assert the
# path points at lib/reline/dialog_transform.rb (our wrap), not at
# irb/input-method.rb (IRB's raw show_doc proc).
#
# Usage (from this gem's bundle):
#
#   bundle exec ruby test/e2e_irb_pty.rb
#
# Exit: 0 on dialog_proc(:show_doc) pointing at our wrap, 1 otherwise.

require "pty"
require "io/console"
require "tmpdir"
require "fileutils"
require "timeout"

LOG_PATH         = ENV.fetch("E2E_IRB_LOG", "/tmp/e2e_irb/output.bin")
EXPECTED_PATH_RE = %r{lib/reline/dialog_transform\.rb}
PROBE_LINE       = 'puts %|<<SHOWDOC=#{Reline.dialog_proc(:show_doc).dialog_proc.source_location.inspect}>>|'

def drain(reader, into:, max_seconds: 0.6)
  deadline = Time.now + max_seconds
  while Time.now < deadline
    begin
      chunk = reader.read_nonblock(8192)
      into << chunk if chunk
    rescue IO::WaitReadable
      IO.select([reader], nil, nil, 0.1)
    rescue EOFError
      break
    end
  end
end

def wait_for(reader, into:, pattern:, timeout: 30)
  deadline = Time.now + timeout
  while Time.now < deadline
    begin
      chunk = reader.read_nonblock(8192)
      into << chunk
      return true if into.match?(pattern)
    rescue IO::WaitReadable
      IO.select([reader], nil, nil, 0.2)
    rescue EOFError
      return false
    end
  end
  false
end

FileUtils.mkdir_p(File.dirname(LOG_PATH))

scratch = Dir.mktmpdir("reline-dialog-transform-e2e-")

File.write(File.join(scratch, ".reline-dialog-transform.rb"), <<~CONF)
  Reline::DialogTransform.install! do |t|
    t.use ->(text, _ctx) { text.upcase }
  end
CONF

File.write(File.join(scratch, ".irbrc"), <<~IRBRC)
  require "reline/dialog_transform"
IRBRC

env = {
  "HOME" => scratch,
  "TERM" => ENV["TERM"] || "xterm-256color",
}

begin
  PTY.spawn(env, "bundle", "exec", "irb") do |reader, writer, pid|
    buffer = String.new(encoding: "ASCII-8BIT")

    unless wait_for(reader, into: buffer, pattern: /irb\(main\):\d+(:\d+)?>/, timeout: 90)
      File.binwrite(LOG_PATH, buffer)
      Process.kill(:TERM, pid) rescue nil
      Process.wait(pid) rescue nil
      abort "TIMEOUT waiting for first prompt (captured #{buffer.bytesize} bytes)"
    end

    drain(reader, into: buffer, max_seconds: 0.5)

    writer.write(PROBE_LINE + "\n")
    writer.flush
    drain(reader, into: buffer, max_seconds: 2.0)

    writer.write("exit\n")
    drain(reader, into: buffer, max_seconds: 1.5)

    begin
      Timeout.timeout(5) { Process.wait(pid) }
    rescue Timeout::Error
      Process.kill(:KILL, pid) rescue nil
    end

    File.binwrite(LOG_PATH, buffer)
  end
ensure
  %w[.reline-dialog-transform.rb .irbrc .irb_history .irb-cache .reline_history].each do |name|
    path = File.join(scratch, name)
    File.delete(path) if File.exist?(path)
  end
  Dir.rmdir(scratch) rescue nil
end

raw     = File.binread(LOG_PATH).force_encoding("UTF-8")
clean   = raw.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
no_ansi = clean.gsub(/\e\[[0-9;?]*[A-Za-z]/, "").gsub(/\e\][^\a]*\a/, "")

# Match the evaluated output line (`<<SHOWDOC=["path", lineno]>>`),
# not the echoed input where the embedded `#{...}` is still literal.
probe_match = no_ansi.match(/<<SHOWDOC=\["([^"]+)",\s*(\d+)\]>>/)
detected_at = probe_match ? "#{probe_match[1]}:#{probe_match[2]}" : nil
matches     = detected_at && detected_at.match?(EXPECTED_PATH_RE)

puts "===== E2E summary ====="
puts "Captured bytes:    #{raw.bytesize}"
if probe_match
  puts "Probe captured:    #{detected_at}"
  if matches
    puts "Wrap registered:   YES — :show_doc points at our wrap (lib/reline/dialog_transform.rb)"
  else
    puts "Wrap registered:   NO — :show_doc was set by something else after our reinstall!"
  end
else
  puts "Probe captured:    (no <<SHOWDOC=...>> sentinel found)"
end
puts "Raw stream saved to: #{LOG_PATH}"
puts "======================="
exit(matches ? 0 : 1)
