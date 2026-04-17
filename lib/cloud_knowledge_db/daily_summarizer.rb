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
      与えられた英語原文1本から、読者が元記事を読まなくても主要な事実・数値・仕様を把握できるだけの、情報量のある日本語の解説文を作成してください。
      規則:
        - 出力は段落形式の読み物。箇条書き（行頭の `-` や `*`）・番号付きリスト・表・区切り線 `---` は使わない。
        - 必要に応じて段落を分ける。1記事あたり 2〜5 段落が目安。無理に削らず、重要な情報は全て残す。
        - 各段落は意味のまとまりで区切り、数値・制限値・対象リージョン・日付・API 名・料金・エディション名などの具体情報を文中に織り込む。
        - 固有名詞・数値・設定名・API 名・機能名は原文のまま（例: Amazon Bedrock, SWE-bench, CI/CD）。
        - 文体は技術文書として中立な「です/ます」調。スラング・方言・絵文字・装飾語尾は禁止。
        - 前置き（「この記事では…」など）や後書き（「まとめ」など）、再度のタイトル出力は一切行わない。
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
