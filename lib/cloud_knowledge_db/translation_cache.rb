# frozen_string_literal: true
require 'fileutils'

module CloudKnowledgeDb
  # tmpdir を毎回新規で切る設計では、再実行のたびに Haiku が非決定的な翻訳を
  # 返して別 content_hash を量産してしまう。翻訳 MD をファイル名キー
  # ({date}-{short}-{slug}.md) で永続化し、同一原稿の再翻訳をなくす。
  class TranslationCache
    def initialize(cache_dir)
      @cache_dir = cache_dir
    end

    def fetch(basename)
      path = File.join(@cache_dir, basename)
      return nil unless File.exist?(path)
      File.read(path, encoding: 'utf-8')
    end

    def store(basename, content)
      FileUtils.mkdir_p(@cache_dir)
      File.write(File.join(@cache_dir, basename), content)
    end
  end
end
