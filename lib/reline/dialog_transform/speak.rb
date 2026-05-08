# frozen_string_literal: true

module Reline
  module DialogTransform
    # Speak transform — the joke-tier transform from spec §7. Passes
    # text through unchanged; the side effect is reading it aloud via
    # AVSpeechSynthesizer (soft-loaded through apple_sdk_mac).
    #
    # Defaults are deliberately conservative:
    #   - enabled gates on ENV["RELINE_SPEAK"] (default off — speech
    #     is opt-in so docs don't randomly start talking)
    #   - truncate_to caps the utterance at 200 chars (RDoc payloads
    #     of 1000+ chars would otherwise lock the speaker for half
    #     a minute on each TAB hover)
    #   - interrupt cancels the previous utterance so rapid TAB
    #     cycling doesn't queue overlapping speech
    class Speak
      DEFAULT_RATE        = 0.5
      DEFAULT_PITCH       = 1.0
      DEFAULT_VOLUME      = 1.0
      DEFAULT_TRUNCATE_TO = 200
      DEFAULT_ENABLED     = -> { ENV["RELINE_SPEAK"] == "1" }

      attr_reader :voice

      def initialize(voice: nil, rate: DEFAULT_RATE, pitch: DEFAULT_PITCH,
                     volume: DEFAULT_VOLUME, async: true,
                     truncate_to: DEFAULT_TRUNCATE_TO, interrupt: true,
                     enabled: nil, speech_proc: nil)
        @voice       = voice
        @rate        = rate
        @pitch       = pitch
        @volume      = volume
        @async       = async
        @truncate_to = truncate_to
        @interrupt   = interrupt
        @enabled     = enabled || DEFAULT_ENABLED
        @speech_proc = speech_proc || build_default_speech_proc
      end

      def call(text, _ctx)
        return text if text.nil?
        return text if text.empty?
        return text unless @enabled.call
        invoke_speech(text)
        text
      end

      private

      def invoke_speech(text)
        return if @speech_proc.nil?
        spoken = @truncate_to ? text[0...@truncate_to] : text
        @speech_proc.call(
          spoken,
          voice: @voice,
          rate: @rate,
          pitch: @pitch,
          volume: @volume,
          interrupt: @interrupt,
          async: @async,
        )
      rescue StandardError => e
        warn "[reline-dialog-transform] speak: #{e.class}: #{e.message}" if ENV["RELINE_DIALOG_TRANSFORM_DEBUG"]
      end

      def build_default_speech_proc
        require "apple_sdk_mac"
        avf_speech_proc
      rescue LoadError => e
        warn "[reline-dialog-transform] apple_sdk_mac unavailable: #{e.message}" if ENV["RELINE_DIALOG_TRANSFORM_DEBUG"]
        nil
      end

      # Production speech_proc: drives AVSpeechSynthesizer through
      # apple_sdk_mac's Apple.discover. Memoizes the synthesizer per
      # Speak instance so consecutive utterances share one queue and
      # interrupt:true can stop the previous utterance cleanly.
      def avf_speech_proc
        synth_holder = []
        ->(text, voice:, rate:, pitch:, volume:, interrupt:, async:) {
          utterance_klass = ::Apple.discover(
            framework: :AVFoundation,
            klass: :AVSpeechUtterance,
            swift_initializer: "init(string:)"
          )
          utterance = utterance_klass.new(string: text)
          utterance.rate = rate if rate
          utterance.pitchMultiplier = pitch if pitch
          utterance.volume = volume if volume
          if voice
            voice_klass = ::Apple.discover(
              framework: :AVFoundation,
              klass: :AVSpeechSynthesisVoice,
              class_method: "voiceWithLanguage:"
            )
            voice_obj = voice_klass.voiceWithLanguage(voice)
            utterance.voice = voice_obj if voice_obj
          end
          synth = synth_holder[0] ||= ::Apple.discover(
            framework: :AVFoundation,
            klass: :AVSpeechSynthesizer
          ).new
          synth.stopSpeakingAtBoundary(0) if interrupt
          synth.speakUtterance(utterance)
          # async is implicit in AVSpeechSynthesizer (it always queues
          # to a background dispatch queue); we accept the kwarg for
          # forward compatibility with sync-mode wrappers.
          _ = async
        }
      end
    end
  end
end
