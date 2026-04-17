# frozen_string_literal: true
require_relative 'runner'

module CloudKnowledgeDb
  class ContentClassifier
    SYSTEM_PROMPT = <<~EN.freeze
      You classify a Japanese cloud-tech blog article into exactly ONE of: aws, gcp, gws, gitlab, none.
      Output the single lowercase label only. No explanation, no punctuation.
    EN

    LABELS = %w[aws gcp gws gitlab none].freeze

    def initialize(provider: 'claude', model: 'haiku')
      @runner = Runner.build(provider: provider, model: model)
    end

    # @return [String] one of LABELS
    def classify(title:, body:, tags:)
      content = "TITLE: #{title}\nTAGS: #{tags.join(', ')}\nBODY: #{body[0, 800]}"
      prompt = "#{SYSTEM_PROMPT}\n\n---\n\n#{content}"
      raw = @runner.execute(prompt).strip.downcase
      LABELS.include?(raw) ? raw : 'none'
    end
  end
end
