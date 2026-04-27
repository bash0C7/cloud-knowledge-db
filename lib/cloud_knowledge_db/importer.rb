# frozen_string_literal: true
require_relative 'config'

module CloudKnowledgeDb
  class Importer
    def initialize(config: Config.load)
      @source_lang = build_source_lang_map(config['sources'] || {})
    end

    # Returns nil when content passes all checks; returns a human-readable
    # rejection reason string when any predicate rejects.
    def validate(content:, source:)
      return "unknown_source: #{source.inspect}" if unknown_source?(source)
      nil
    end

    private

    def unknown_source?(source)
      !@source_lang.key?(source)
    end

    def build_source_lang_map(sources_cfg)
      map = {}
      sources_cfg.each_value do |entry|
        lang = entry['expected_lang']
        if entry['source']
          map[entry['source']] = lang
        end
        (entry['tag_to_source'] || {}).each_value do |mapped|
          map[mapped] = lang
        end
      end
      map
    end
  end
end
