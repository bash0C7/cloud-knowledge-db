# frozen_string_literal: true

module CloudKnowledgeDb
  class ContentClassifier
    SYSTEM_PROMPT = <<~EN.freeze
      You classify a Japanese cloud-tech blog article into exactly ONE of: aws, gcp, gws, gitlab, none.
      Output the single lowercase label only. No explanation, no punctuation.
    EN

    LABELS = %w[aws gcp gws gitlab none].freeze
    MAX_TOKENS = 16

    def initialize(client:, model_resolver:)
      @client         = client
      @model_resolver = model_resolver
    end

    def classify(title:, body:, tags:)
      content = "TITLE: #{title}\nTAGS: #{tags.join(', ')}\nBODY: #{body[0, 800]}"
      response = @client.messages.create(
        model:    @model_resolver.resolve(:haiku),
        system:   [{ type: 'text', text: SYSTEM_PROMPT, cache_control: { type: 'ephemeral' } }],
        messages: [{ role: 'user', content: content }],
        max_tokens: MAX_TOKENS
      )
      raw = response.content.first.text.strip.downcase
      LABELS.include?(raw) ? raw : 'none'
    end
  end
end
