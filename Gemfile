# frozen_string_literal: true
source "https://rubygems.org"

gemspec

# irb is a bundled gem in Ruby 3+ but Bundler in Ruby 4 still requires
# an explicit entry to expose `bundle exec irb`. examples/quick_start.rb
# spawns irb so it needs to be reachable from this gem's own bundle.
gem "irb"

# Note: translation_mac-locale and rb-apple-sdk-mac are soft deps loaded at
# runtime by Translate / Speak transforms respectively. They are NOT pulled
# in by the gemspec; consumers add them to their own Gemfile when they want
# those transforms to do anything beyond passthrough.
