# frozen_string_literal: true
require_relative 'claude_runner'
require_relative 'ollama_runner'
require_relative 'llama_cpp_runner'

module CloudKnowledgeDb
  # Factory returning a concrete runner for a given (provider, model) pair.
  # Consumers (Translator / DailySummarizer / ContentClassifier) depend on
  # this module, not on the concrete runner classes.
  module Runner
    PROVIDERS = %w[claude local_ollama local_llama].freeze

    def self.build(provider:, model:)
      case provider.to_s
      when 'claude'       then ClaudeRunner.new(model: model)
      when 'local_ollama' then OllamaRunner.new(model: model)
      when 'local_llama'  then LlamaCppRunner.new(model: model)
      else
        raise ArgumentError,
              "unknown runner provider: #{provider.inspect} (supported: #{PROVIDERS.join(', ')})"
      end
    end

    # 起動前の可用性チェック。claude は CLI 前提で ensure_available! を持たないため no-op。
    def self.ensure_available!(provider:)
      case provider.to_s
      when 'local_ollama' then OllamaRunner.ensure_available!
      when 'local_llama'  then LlamaCppRunner.ensure_available!
      end
    end
  end
end
