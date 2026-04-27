# frozen_string_literal: true
require_relative 'config'

module CloudKnowledgeDb
  class Importer
    REPLACEMENT_CHAR     = "\u{FFFD}"
    HTML_RATIO_THRESHOLD = 0.05
    HTML_TAG_REGEX       = /<[^>]{1,200}>/.freeze

    def initialize(config: Config.load)
      @source_lang = build_source_lang_map(config['sources'] || {})
    end

    # Returns nil when content passes all checks; returns a human-readable
    # rejection reason string when any predicate rejects.
    def validate(content:, source:)
      return "unknown_source: #{source.inspect}" if unknown_source?(source)
      return 'mojibake: U+FFFD replacement char present' if self.class.mojibake?(content)
      return "html_heavy: tag char ratio > #{HTML_RATIO_THRESHOLD}" if self.class.html_heavy?(content)
      nil
    end

    # Class-level mirrors so db:scan_pollution can reuse the predicates
    # without instantiating an Importer.
    def self.mojibake?(content)
      return false if content.nil?
      content.include?(REPLACEMENT_CHAR)
    end

    def self.html_heavy?(content)
      return false if content.nil? || content.empty?
      tag_chars = content.scan(HTML_TAG_REGEX).sum(&:length)
      (tag_chars.to_f / content.length) > HTML_RATIO_THRESHOLD
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
