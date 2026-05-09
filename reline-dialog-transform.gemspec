# frozen_string_literal: true

require_relative "lib/reline/dialog_transform/version"

Gem::Specification.new do |spec|
  spec.name = "reline-dialog-transform"
  spec.version = Reline::DialogTransform::VERSION
  spec.authors = ["bash0C7"]
  spec.email = ["ksb.4038.nullpointer+github@gmail.com"]

  spec.summary = "Compose Reline dialog text transforms (translate, custom callables)"
  spec.description = <<~DESC
    Hooks Reline.add_dialog_proc and applies an ordered chain of text
    transforms to the dialog contents. The built-in translate transform
    delegates to translation_mac-locale. Configured via a Ruby DSL in a
    dotfile at the project or home root.
  DESC
  spec.homepage = "https://github.com/bash0C7/reline-dialog-transform"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir.chdir(__dir__) do
    Dir.glob(["lib/**/*.rb", "README.md", "LICENSE.txt"]).reject { |f| File.directory?(f) }
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "reline", "~> 0.6"

  spec.add_development_dependency "test-unit", "~> 3.6"
  spec.add_development_dependency "rake", "~> 13.0"
end
