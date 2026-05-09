# frozen_string_literal: true

module Reline
  module DialogTransform
    # Translate transform — runs each text through a translator (an
    # object responding to #translate(text)). The translator is either
    # injected (tests, custom providers) or auto-built from target_lang
    # via translation_mac-locale (soft-loaded; LoadError → identity).
    class Translate
      attr_reader :target_lang, :source_lang

      def initialize(target_lang: nil, source_lang: nil, min_length: 2,
                     skip_if: nil, on_error: :passthrough, translator: nil)
        @target_lang = target_lang
        @source_lang = source_lang
        @min_length = min_length
        @skip_if = skip_if
        @on_error = on_error
        @translator = translator || build_default_translator
      end

      def call(text, ctx)
        return text if text.nil?
        return text if text.length < @min_length
        return text if text.include?("\e")
        return text if @skip_if && @skip_if.call(text, ctx)
        return text if @translator.nil?
        translate_with_policy(text)
      end

      private

      def translate_with_policy(text)
        @translator.translate(text)
      rescue StandardError
        case @on_error
        when :raise then raise
        when :nil   then nil
        else text
        end
      end

      def build_default_translator
        return nil if @target_lang.nil?
        require "translation_mac/locale"
        kwargs = { target_lang: @target_lang.to_s }
        kwargs[:source_lang] = @source_lang.to_s if @source_lang
        ::TranslationMac::Locale::Translator.new(**kwargs)
      rescue LoadError => e
        warn "[reline-dialog-transform] translation_mac/locale unavailable: #{e.message}" if ENV["RELINE_DIALOG_TRANSFORM_DEBUG"]
        nil
      end
    end
  end
end
