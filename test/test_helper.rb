# frozen_string_literal: true
require "test-unit"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

ENV["RELINE_DIALOG_TRANSFORM_AUTOLOAD"] = "off"
