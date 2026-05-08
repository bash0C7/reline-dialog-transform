# frozen_string_literal: true

require "reline"

require_relative "dialog_transform/version"
require_relative "dialog_transform/builder"
require_relative "dialog_transform/chain"
require_relative "dialog_transform/loader"

module Reline
  module DialogTransform
    # Public entry point for in-code use. Build a Builder, yield it to
    # the caller, then wire the resulting chain into Reline against
    # `dialog:` (default :show_doc).
    #
    # `reline:` is the Reline gateway for dependency injection — tests
    # pass a FakeReline; production picks up the real Reline module.
    def self.install!(dialog: :show_doc, default_lang: nil, reline: Reline)
      builder = Builder.new
      builder.default_lang(default_lang) if default_lang
      yield builder if block_given?
      install_chain(builder.to_chain, dialog: dialog, reline: reline)
    end

    # Public entry point for dotfile-driven configuration. Discovers
    # `.reline-dialog-transform.rb` in pwd / home (or uses caller-given
    # `paths:`), evaluates them into a single Builder, and registers.
    def self.load!(dialog: :show_doc, paths: nil, reline: Reline)
      paths ||= Loader.discover
      builder = Loader.build(paths: paths)
      install_chain(builder.to_chain, dialog: dialog, reline: reline)
    end

    # Wraps whatever dialog_proc is currently registered for `dialog:`,
    # mutating its DialogRenderInfo#contents through the chain. Falls
    # back to no-dialog (nil) when there's nothing to wrap or the
    # existing proc returns nil — never silently fabricates a dialog.
    def self.install_chain(chain, dialog:, reline:)
      existing_struct = reline.dialog_proc(dialog)
      existing_proc   = existing_struct ? existing_struct.dialog_proc : nil

      wrapped = -> {
        info = existing_proc ? instance_exec(&existing_proc) : nil
        return nil if info.nil?
        ctx = {}
        info.contents = info.contents.map { |line| chain.call(line, ctx) }
        info
      }

      reline.add_dialog_proc(dialog, wrapped, Reline::DEFAULT_DIALOG_CONTEXT)
    end
  end
end

if ENV["RELINE_DIALOG_TRANSFORM_AUTOLOAD"] != "off"
  begin
    Reline::DialogTransform.load!
  rescue StandardError => e
    warn "[reline-dialog-transform] auto-load failed: #{e.class}: #{e.message}"
  end
end
