# frozen_string_literal: true
require_relative 'runner'

module CloudKnowledgeDb
  class DailySummarizer
    SYSTEM_PROMPT = <<~JA.freeze
      あなたはクラウドプラットフォームの公式技術ブログ新着記事をまとめるテクニカルライターです。
      与えられた1日分の英語原文記事リストから、以下の構造の日本語Markdown記事を作成してください。
      規則:
        - 見出しは「# YYYY-MM-DD <PROVIDER> まとめ」とする。
        - 各記事は「## [<タイトル>](<URL>)」の形式で見出し全体をリンクにし、その配下に要点3つ以内の日本語箇条書きを置く。タイトルは英語原題のまま残す。
        - 末尾に単独のリンク行（例: `[記事リンク](...)` やベアURL）を出力してはならない。
        - 文体は技術文書として中立な「です/ます」調。スラング・方言・絵文字・装飾語尾は禁止。
        - 出力は本文Markdownのみ。前置きや結語は不要。
    JA

    def initialize(provider: 'local_ollama', model: 'gemma4')
      @runner = Runner.build(provider: provider, model: model)
    end

    # @param provider_short [String] e.g. "aws"
    # @param date [String] YYYY-MM-DD
    # @param articles [Array<Hash>] each: {title:, url:, body:} (body is English)
    # @return [String] Markdown summary article (Japanese)
    def summarize(provider_short:, date:, articles:)
      user_content = build_user_content(provider_short, date, articles)
      prompt = "#{SYSTEM_PROMPT}\n\n---\n\n#{user_content}"
      @runner.execute(prompt)
    end

    private

    def build_user_content(provider_short, date, articles)
      header = "PROVIDER: #{provider_short.upcase}\nDATE: #{date}\n\n"
      body   = articles.map { |a| "TITLE: #{a[:title]}\nURL: #{a[:url]}\nBODY:\n#{a[:body]}\n" }.join("\n---\n")
      header + body
    end
  end
end
