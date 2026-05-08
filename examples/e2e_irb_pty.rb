#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Phase 6 real-TUI E2E driver.
#
# Spawns `bundle exec irb` under a PTY, types a partial Apple SDK
# identifier, sends TAB twice to trigger the autocomplete + show_doc
# dialog, captures the raw terminal byte stream, and reports any
# Japanese codepoints found (i.e. the wrap actually translated the
# Apple SDK doc through translation_mac-locale).
#
# Setup an isolated HOME so the user's real ~/.irbrc is untouched:
#
#   mkdir -p /tmp/e2e_irb/home
#   cat > /tmp/e2e_irb/home/.reline-dialog-transform.rb <<'CONF'
#     default_lang :ja
#     translate
#   CONF
#   cat > /tmp/e2e_irb/home/.irbrc <<'IRBRC'
#     require "apple_sdk_mac"
#     require "apple_sdk_mac/irb"
#     AppleSDKMac::IRB.install!
#   IRBRC
#
# Then run from a bundle that has apple_sdk_mac + reline-dialog-
# transform + translation_mac-locale all path-loaded (e.g.
# rb-apple-sdk-mac):
#
#   cd /Users/you/dev/src/github.com/bash0C7/rb-apple-sdk-mac
#   HOME=/tmp/e2e_irb/home \
#   XDG_CACHE_HOME=/Users/you/.cache \
#   TERM=xterm-256color \
#   bundle exec ruby ../reline-dialog-transform/examples/e2e_irb_pty.rb \
#     "Apple::Foundation::URL.app"
#
# XDG_CACHE_HOME points at the real apple_sdk_mac KB cache so the
# isolated HOME doesn't strand the autocomplete with an empty KB.
#
# Exit code: 0 on Japanese detected, 1 on capture without any
# Japanese codepoints (suggests translation didn't run end-to-end).

require "pty"
require "io/console"
require "timeout"

LOG_PATH = ENV.fetch("E2E_IRB_LOG", "/tmp/e2e_irb/output.bin")
TARGET   = ARGV[0] || "Apple::Foundation::URL.app"

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

require "fileutils"
FileUtils.mkdir_p(File.dirname(LOG_PATH))

PTY.spawn("bundle exec irb") do |reader, writer, pid|
  buffer = String.new(encoding: "ASCII-8BIT")

  # IRB 1.18 + Ruby 4 prompt is `irb(main):001> `; older toolchains
  # rendered `irb(main):001:0> `. Match both.
  unless wait_for(reader, into: buffer, pattern: /irb\(main\):\d+(:\d+)?>/, timeout: 90)
    File.binwrite(LOG_PATH, buffer)
    Process.kill(:TERM, pid) rescue nil
    Process.wait(pid) rescue nil
    abort "TIMEOUT waiting for first prompt (captured #{buffer.bytesize} bytes)"
  end

  drain(reader, into: buffer, max_seconds: 0.5)

  writer.write(TARGET)
  writer.flush
  drain(reader, into: buffer, max_seconds: 0.5)

  writer.write("\t")
  writer.flush
  drain(reader, into: buffer, max_seconds: 1.5)

  writer.write("\t")
  writer.flush
  # First-call latency on translation_mac-locale's helper warm-up
  # plus apple_sdk_mac's KB lookup can take a few seconds.
  drain(reader, into: buffer, max_seconds: 8.0)

  writer.write("\x03")
  drain(reader, into: buffer, max_seconds: 0.4)
  writer.write("exit\n")
  drain(reader, into: buffer, max_seconds: 1.0)

  begin
    Timeout.timeout(5) { Process.wait(pid) }
  rescue Timeout::Error
    Process.kill(:KILL, pid) rescue nil
  end

  File.binwrite(LOG_PATH, buffer)
end

raw = File.binread(LOG_PATH).force_encoding("UTF-8")
clean = raw.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
no_ansi = clean.gsub(/\e\[[0-9;?]*[A-Za-z]/, "").gsub(/\e\][^\a]*\a/, "")

ja_chars = no_ansi.scan(/[぀-ゟ゠-ヿ一-鿿]/)

puts "===== E2E summary ====="
puts "Target identifier: #{TARGET}"
puts "Captured bytes:    #{raw.bytesize}"
if ja_chars.empty?
  puts "Japanese codepoints: NO (translation pipeline likely passthrough)"
else
  puts "Japanese codepoints: #{ja_chars.size} found, sample: #{ja_chars.first(40).join}"
end
puts "Raw stream saved to: #{LOG_PATH}"
puts "======================="
exit(ja_chars.empty? ? 1 : 0)
