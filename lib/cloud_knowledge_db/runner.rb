# frozen_string_literal: true
require_relative 'claude_runner'
require_relative 'ollama_runner'

module CloudKnowledgeDb
  # Factory returning a concrete runner for a given (provider, model) pair.
  # Consumers (Translator / DailySummarizer / ContentClassifier) depend on
  # this module, not on the concrete runner classes.
  module Runner
    PROVIDERS = %w[claude local_ollama].freeze

    def self.build(provider:, model:)
      case provider.to_s
      when 'claude'       then ClaudeRunner.new(model: model)
      when 'local_ollama' then OllamaRunner.new(model: model)
      else
        raise ArgumentError,
              "unknown runner provider: #{provider.inspect} (supported: #{PROVIDERS.join(', ')})"
      end
    end
  end
end
