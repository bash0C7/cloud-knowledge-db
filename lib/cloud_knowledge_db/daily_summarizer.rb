# frozen_string_literal: true
require_relative 'runner'

module CloudKnowledgeDb
  class DailySummarizer
    # Per-article prompt kept intentionally small and rigid so gemma4's
    # instruction following stays reliable: we only ask for bullets, never
    # for the heading or the link (those are assembled in Ruby so the LLM
    # cannot break the layout).
    SYSTEM_PROMPT = <<~JA.freeze
      あなたはクラウドプラットフォームの公式技術ブログ1記事を日本語で要約するテクニカルライターです。
      与えられた英語原文1本から、要点の日本語箇条書きだけを生成してください。
      規則:
        - 出力は箇条書きのみ。行頭は `-` を使う。
        - 要点は 4〜7 個。固有名詞・数値・設定名・API名は原文のまま残す（例: Amazon Bedrock, SWE-bench, CI/CD）。
        - 各行は1トピック、60〜120文字程度で簡潔に。必要十分な文脈は残す。
        - 文体は技術文書として中立な「です/ます」調。スラング・方言・絵文字・装飾語尾は禁止。
        - 前置き・後書き・見出し・表・区切り線 `---` は一切出力しない。
        - 英語の要約を出力してはならない（必ず日本語）。
    JA

    def initialize(provider: 'local_ollama', model: 'gemma4')
      @runner = Runner.build(provider: provider, model: model)
    end

    # @param provider_short [String] e.g. "aws"
    # @param date [String] YYYY-MM-DD
    # @param articles [Array<Hash>] each: {title:, url:, body:} (body is English)
    # @return [String] Markdown summary article (Japanese)
    def summarize(provider_short:, date:, articles:)
      header   = "# #{date} #{provider_short.upcase} まとめ"
      sections = articles.map { |a| build_section(a) }
      ([header] + sections).join("\n\n") + "\n"
    end

    private

    def build_section(article)
      bullets = @runner.execute(build_prompt(article)).strip
      "## [#{article[:title]}](#{article[:url]})\n\n#{bullets}"
    end

    def build_prompt(article)
      "#{SYSTEM_PROMPT}\n\n---\n\nTITLE: #{article[:title]}\nURL: #{article[:url]}\nBODY:\n#{article[:body]}"
    end
  end
end
