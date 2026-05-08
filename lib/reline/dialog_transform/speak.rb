# frozen_string_literal: true

module Reline
  module DialogTransform
    # Phase 1 stub — captures voice (and friends) as readable attrs so
    # Builder slot tests can verify the latest opts. AVSpeechSynthesizer
    # bridge via apple_sdk_mac is wired in Phase 4.
    class Speak
      attr_reader :voice

      def initialize(voice: nil, **_opts)
        @voice = voice
      end
    end
  end
end
