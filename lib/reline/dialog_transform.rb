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
      builder = Builder.new(default_lang: default_lang)
      yield builder if block_given?
      install_chain(builder.to_chain, dialog: dialog, reline: reline)
    end

    # Discovers a dotfile and runs it via Kernel#load. The dotfile body
    # is plain Ruby and is expected to call Reline::DialogTransform.install!
    # itself.
    #
    # Selection rules:
    #   - Default (paths: nil): Loader.find is used. Project (CWD) takes
    #     precedence over home; only one file is loaded; nil if neither
    #     dotfile exists.
    #   - Explicit paths: array is searched in caller-supplied order
    #     (Array#find). The first existing path is loaded. The caller
    #     is responsible for ordering — there is no automatic project-
    #     before-home reordering when paths is given.
    #
    # Returns the loaded path, or nil when none of the candidates exist.
    def self.load!(paths: nil)
      target =
        if paths
          paths.find { |path| File.exist?(path) }
        else
          Loader.find
        end
      return nil unless target
      load target
      target
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
