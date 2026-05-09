# frozen_string_literal: true

require_relative "translate"
require_relative "chain"

module Reline
  module DialogTransform
    # Pure array-push wrapper. translate/use append the produced
    # transform to an internal list; to_chain returns a Chain over a
    # snapshot of that list. default_lang is captured at construction
    # time and forwarded into translate when target_lang is omitted at
    # the call site.
    class Builder
      def initialize(default_lang: nil)
        @default_lang = default_lang
        @transforms = []
      end

      def translate(**opts)
        opts[:target_lang] ||= @default_lang
        @transforms << Translate.new(**opts)
        self
      end

      def use(callable)
        @transforms << callable
        self
      end

      def to_chain
        Chain.new(@transforms.dup)
      end
    end
  end
end
