# frozen_string_literal: true
require_relative 'ollama_runner'

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

    def initialize(model: 'gemma4')
      @runner = OllamaRunner.new(model: model)
    end

    # @param article_md [String] English article
    # @return [String] Japanese translation
    def translate(article_md)
      prompt = "#{SYSTEM_PROMPT}\n\n---\n\n#{article_md}"
      @runner.execute(prompt)
    end
  end
end
