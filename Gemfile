# frozen_string_literal: true
source "https://rubygems.org"

gemspec

# irb is a bundled gem in Ruby 3+ but Bundler in Ruby 4 still requires
# an explicit entry to expose `bundle exec irb`. quick_start_example.rb
# spawns irb so it needs to be reachable from this gem's own bundle.
gem "irb"

# Demo deps for quick_start_example.rb. Production users add the soft
# deps to their own Gemfile; these entries are for THIS gem's
# development bundle only.
#
# Canonical upstream: https://github.com/bash0C7/rb-apple-sdk-mac
#
# Path-loaded (not git-source) because rb-apple-sdk-mac's extconf.rb
# requires swift_gem/mkmf which fails to resolve when bundler installs
# from git source. Path mode reuses the already-compiled
# lib/apple_sdk_mac/apple_sdk_mac_runtime.bundle from the local clone.
# Run `ghq get https://github.com/bash0C7/rb-apple-sdk-mac` if it is
# not yet checked out at ../rb-apple-sdk-mac.
gem "rb-apple-sdk-mac",        path: "../rb-apple-sdk-mac"

# Transitive sibling deps of rb-apple-sdk-mac that are NOT published
# on rubygems.org. Same ghq layout assumption.
gem "rb-translation-mac",      path: "../rb-translation-mac"
gem "translation_mac-locale",  path: "../rb-translation-mac/locale"
gem "rb-foundation-model-mac", path: "../rb-foundation-model-mac"
gem "rb-apple-sdk-knowledge",  path: "../rb-apple-sdk-knowledge"

# swift_gem: native-extension build helper; rb-apple-sdk-mac uses it
# at compile time. Git source matches rb-apple-sdk-mac's own Gemfile.
gem "swift_gem", git: "https://github.com/bash0C7/swift_gem"
