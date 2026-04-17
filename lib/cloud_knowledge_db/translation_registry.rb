# frozen_string_literal: true

module CloudKnowledgeDb
  # Haiku 翻訳は非決定的で再実行のたびに別 content_hash を生成するため、
  # content_hash UNIQUE では冪等性を担保できない。translate phase 前に
  # url ベースで既存翻訳を検出してスキップする。
  class TranslationRegistry
    def initialize(db)
      @db = db
    end

    def has_translation?(source:, url:)
      return false if @db.nil?
      return false if source.nil? || url.nil? || url.to_s.empty?

      rows = @db.execute(
        'SELECT 1 FROM memories WHERE source = ? AND content LIKE ? LIMIT 1',
        [source, "%#{url}%"]
      )
      !rows.empty?
    end
  end
end
