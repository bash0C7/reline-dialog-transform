# frozen_string_literal: true

module Reline
  module DialogTransform
    # Holds the ordered list of transforms produced by Builder#to_chain.
    # Phase 1 only needs the accessor for slot-semantics tests; the
    # actual #call(text, ctx) execution path is wired in a later phase
    # alongside the Reline dialog-proc hook.
    class Chain
      attr_reader :transforms

      def initialize(transforms)
        @transforms = transforms
      end
    end
  end
end
