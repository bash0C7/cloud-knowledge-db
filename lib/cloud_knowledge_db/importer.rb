# frozen_string_literal: true
require_relative 'config'

module CloudKnowledgeDb
  class Importer
    REPLACEMENT_CHAR     = "\u{FFFD}"
    HTML_RATIO_THRESHOLD = 0.05
    HTML_TAG_REGEX       = /<[^>]+>/.freeze
    KANA_REGEX           = /[぀-ヿ･-ﾟ]/.freeze
    KANA_THRESHOLD       = 0.05
    LANG_MIN_CONTENT_LEN = 50

    # Hash<String, String> — DB source value -> expected_lang ('en' | 'ja')
    attr_reader :source_lang

    def initialize(config: Config.load)
      @source_lang = build_source_lang_map(config['sources'] || {})
    end

    # Returns nil when content passes all checks; returns a human-readable
    # rejection reason string when any predicate rejects. Note that html_heavy
    # is intentionally NOT a standalone reject — too many false positives on
    # gws/blogs/all Blogger boilerplate. Use db:scan_pollution to surface
    # html_heavy combined with language_mismatch.
    def validate(content:, source:)
      return 'missing_source: frontmatter has no source key' if source.nil?
      return "unknown_source: #{source.inspect}" if unknown_source?(source)
      return 'mojibake: U+FFFD replacement char present' if self.class.mojibake?(content)
      expected = @source_lang[source]
      if expected && self.class.language_mismatch?(content, expected)
        return "language_mismatch: source=#{source} expected=#{expected}"
      end
      nil
    end

    # Class-level mirrors used by db:scan_pollution to apply each predicate
    # independently per row, so the scan output can label which check fired.
    def self.mojibake?(content)
      return false if content.nil?
      content.include?(REPLACEMENT_CHAR)
    end

    def self.html_heavy?(content)
      return false if content.nil? || content.empty?
      tag_chars = content.scan(HTML_TAG_REGEX).sum(&:length)
      (tag_chars.to_f / content.length) > HTML_RATIO_THRESHOLD
    end

    def self.language_mismatch?(content, expected_lang, kana_threshold: KANA_THRESHOLD)
      return false if content.nil? || content.length < LANG_MIN_CONTENT_LEN
      kana_count = content.scan(KANA_REGEX).length
      ratio = kana_count.to_f / content.length
      case expected_lang
      when 'en' then ratio >= kana_threshold
      when 'ja' then ratio < kana_threshold
      else false
      end
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
