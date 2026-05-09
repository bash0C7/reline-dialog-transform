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
      chain = builder.to_chain
      @last_install = { chain: chain, dialog: dialog, reline: reline }
      install_chain(chain, dialog: dialog, reline: reline)
    end

    # Re-applies the most recent install! invocation. Call this after
    # something else has registered a new dialog proc for the same
    # `dialog:` so our wrap layers on top of the newly registered proc.
    #
    # IRB's RelineInputMethod#initialize registers its own :show_doc
    # AFTER .irbrc evaluation completes — overwriting any wrap we
    # installed during .irbrc. The autoload block below prepends that
    # initialize and calls reinstall! after super so the wrap survives.
    #
    # Returns nil and does nothing when install! was never called or
    # was reset (test seam: reset_last_install!).
    def self.reinstall!(reline: nil)
      return nil unless @last_install
      target_reline = reline || @last_install[:reline]
      install_chain(@last_install[:chain],
                    dialog: @last_install[:dialog],
                    reline: target_reline)
    end

    # Test seam — clears the cached install! invocation.
    def self.reset_last_install!
      @last_install = nil
    end
    private_class_method :reset_last_install!

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

  # IRB::RelineInputMethod#initialize registers its own :show_doc proc
  # via Reline.add_dialog_proc, AFTER .irbrc has finished. That wipes
  # any wrap we registered during .irbrc. Prepend a hook that re-applies
  # the last install! after super so we layer on top of IRB's :show_doc.
  if defined?(::IRB) && defined?(::IRB::RelineInputMethod)
    ::IRB::RelineInputMethod.prepend(Module.new do
      def initialize(...)
        super
        Reline::DialogTransform.reinstall!
      rescue StandardError => e
        warn "[reline-dialog-transform] post-IRB-init reinstall failed: #{e.class}: #{e.message}"
      end
    end)
  end
end
