# frozen_string_literal: true

module Reline
  module DialogTransform
    # Holds the ordered list of transforms produced by Builder#to_chain
    # and runs them in sequence over (text, ctx). With the default
    # error_isolation = true, a transform that raises is treated as a
    # no-op so a single broken transform doesn't kill the dialog for
    # unrelated downstream transforms or future invocations.
    class Chain
      attr_reader :transforms

      def initialize(transforms, error_isolation: true, max_input_length: nil)
        @transforms = transforms
        @error_isolation = error_isolation
        @max_input_length = max_input_length
      end

      def call(text, ctx)
        return text if too_long?(text)
        @transforms.reduce(text) { |acc, transform| apply(transform, acc, ctx) }
      end

      private

      def too_long?(text)
        @max_input_length && text.respond_to?(:length) && text.length > @max_input_length
      end

      def apply(transform, text, ctx)
        transform.call(text, ctx)
      rescue StandardError => e
        raise unless @error_isolation
        warn "[reline-dialog-transform] #{e.class}: #{e.message}" if ENV["RELINE_DIALOG_TRANSFORM_DEBUG"]
        text
      end
    end
  end
end
