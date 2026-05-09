# frozen_string_literal: true
source "https://rubygems.org"

gemspec

# irb is a bundled gem in Ruby 3+ but Bundler in Ruby 4 still requires
# an explicit entry to expose `bundle exec irb`. quick_start_example.rb
# spawns irb so it needs to be reachable from this gem's own bundle.
gem "irb"

# translation_mac-locale enables `t.translate` for the quick_start
# demo. rb-translation-mac is its runtime dependency. Both are sibling
# repos under the standard ghq layout (../rb-translation-mac).
gem "rb-translation-mac",     path: "../rb-translation-mac"
gem "translation_mac-locale", path: "../rb-translation-mac/locale"
