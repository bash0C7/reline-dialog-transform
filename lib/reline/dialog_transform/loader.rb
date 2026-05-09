# frozen_string_literal: true

module Reline
  module DialogTransform
    # Resolves the dotfile path to load. Project (CWD) takes precedence
    # over home; nil when neither exists. The actual loading is done
    # by Reline::DialogTransform.load! via Kernel#load — Loader's only
    # job is path resolution, deliberately decoupled from execution so
    # tests can verify resolution without spawning Ruby code.
    module Loader
      CONFIG_BASENAME = ".reline-dialog-transform.rb"

      def self.find(home_dir: Dir.home, project_dir: Dir.pwd)
        candidates = [
          File.join(project_dir, CONFIG_BASENAME),
          File.join(home_dir,    CONFIG_BASENAME),
        ]
        candidates.uniq.find { |path| File.exist?(path) }
      end
    end
  end
end
