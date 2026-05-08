# frozen_string_literal: true

module Reline
  module DialogTransform
    # Phase 1 stub — stores the constructor opts as readable attrs so
    # Builder slot tests can assert what the latest call locked in. The
    # full translation_mac-locale wiring lands in Phase 3.
    class Translate
      attr_reader :target_lang, :source_lang

      def initialize(target_lang: nil, source_lang: nil, **_opts)
        @target_lang = target_lang
        @source_lang = source_lang
      end
    end
  end
end
