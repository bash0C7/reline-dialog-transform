# frozen_string_literal: true

require_relative "builder"

module Reline
  module DialogTransform
    # Discovers `.reline-dialog-transform.rb` files in priority order
    # (home first, then project) and evaluates each into a single
    # Builder so the OR-merge slot semantics from spec §4 E apply across
    # the home/project layering.
    module Loader
      CONFIG_BASENAME = ".reline-dialog-transform.rb"

      def self.discover(home_dir: Dir.home, project_dir: Dir.pwd)
        candidates = [
          File.join(home_dir, CONFIG_BASENAME),
          File.join(project_dir, CONFIG_BASENAME),
        ]
        candidates.uniq.select { |path| File.exist?(path) }
      end

      def self.build(paths:)
        builder = Builder.new
        paths.each do |path|
          builder.instance_eval(File.read(path), path)
        end
        builder
      end
    end
  end
end
