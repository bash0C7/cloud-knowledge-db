# frozen_string_literal: true

module CloudKnowledgeDb
  class DailySummarizer
    SYSTEM_PROMPT = <<~JA.freeze
      あなたはクラウドプラットフォームの公式技術ブログ新着記事をまとめるテクニカルライターです。
      与えられた1日分の翻訳済み記事リストから、以下の構造のMarkdown記事を作成してください。
      規則:
        - 見出しは「# YYYY-MM-DD <PROVIDER> まとめ」とする。
        - 各記事は「## <タイトル>」の見出し配下に、要点3つ以内の箇条書き、最後にリンクを付ける。
        - 文体は技術文書として中立な「です/ます」調。スラング・方言・絵文字・装飾語尾は禁止。
        - 出力は本文Markdownのみ。前置きや結語は不要。
    JA

    MAX_TOKENS = 4096

    def initialize(client:, model_resolver:)
      @client         = client
      @model_resolver = model_resolver
    end

    def summarize(provider_short:, date:, translated_articles:)
      user_content = build_user_content(provider_short, date, translated_articles)
      response = @client.messages.create(
        model:    @model_resolver.resolve(:opus),
        system:   [{ type: 'text', text: SYSTEM_PROMPT, cache_control: { type: 'ephemeral' } }],
        messages: [{ role: 'user', content: user_content }],
        max_tokens: MAX_TOKENS
      )
      response.content.first.text
    end

    private

    def build_user_content(provider_short, date, articles)
      header = "PROVIDER: #{provider_short.upcase}\nDATE: #{date}\n\n"
      body   = articles.map { |a| "TITLE: #{a[:title]}\nURL: #{a[:url]}\nBODY:\n#{a[:body_ja]}\n" }.join("\n---\n")
      header + body
    end
  end
end
