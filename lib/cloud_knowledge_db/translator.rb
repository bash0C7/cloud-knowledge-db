# frozen_string_literal: true

module CloudKnowledgeDb
  class Translator
    SYSTEM_PROMPT = <<~EN.freeze
      You are a precise English-to-Japanese translator for cloud platform technical blog articles.
      Translate the provided article to natural Japanese suitable for engineers.
      Rules:
        - Preserve all code blocks, URLs, product names, and technical terms verbatim.
        - Use formal-but-casual technical style (です/ます). Do NOT use slang, dialects, or playful endings.
        - Output ONLY the translation. Do not add explanations or meta commentary.
    EN

    MAX_TOKENS = 4096

    def initialize(client:, model_resolver:)
      @client         = client
      @model_resolver = model_resolver
    end

    def translate(article_md)
      response = @client.messages.create(
        model:    @model_resolver.resolve(:haiku),
        system:   [{ type: 'text', text: SYSTEM_PROMPT, cache_control: { type: 'ephemeral' } }],
        messages: [{ role: 'user', content: article_md }],
        max_tokens: MAX_TOKENS
      )
      response.content.first.text
    end
  end
end
