# frozen_string_literal: true

require_relative "translate"
require_relative "speak"
require_relative "chain"

module Reline
  module DialogTransform
    # DSL builder that accumulates transforms with OR-merge semantics:
    # each named slot (translate / speak / ...) is identified by class,
    # so a later call replaces the earlier instance in-place; anonymous
    # callables registered through #use always append. See spec §4 E.
    class Builder
      def initialize
        @transforms = []
        @default_lang = nil
      end

      def default_lang(lang = nil)
        @default_lang = lang unless lang.nil?
        @default_lang
      end

      def translate(**opts)
        opts[:target_lang] ||= @default_lang
        replace_or_append(Translate.new(**opts))
      end

      def speak(**opts)
        opts[:voice] ||= @default_lang
        replace_or_append(Speak.new(**opts))
      end

      def use(callable)
        @transforms << callable
        self
      end

      def clear!
        @transforms.clear
        @default_lang = nil
        self
      end

      def to_chain
        Chain.new(@transforms.dup)
      end

      private

      def replace_or_append(instance)
        idx = @transforms.find_index { |t| t.class == instance.class }
        if idx
          @transforms[idx] = instance
        else
          @transforms << instance
        end
        self
      end
    end
  end
end
