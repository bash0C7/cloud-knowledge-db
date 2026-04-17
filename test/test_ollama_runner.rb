# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/ollama_runner'

class OllamaRunnerTest < Test::Unit::TestCase
  def test_initializes_with_model
    runner = CloudKnowledgeDb::OllamaRunner.new(model: 'gemma4')
    assert_equal 'gemma4', runner.instance_variable_get(:@model)
  end

  def test_ensure_available_raises_when_daemon_unreachable
    original = ENV['OLLAMA_HOST']
    ENV['OLLAMA_HOST'] = 'http://127.0.0.1:1'
    assert_raise(RuntimeError) do
      CloudKnowledgeDb::OllamaRunner.ensure_available!
    end
  ensure
    ENV['OLLAMA_HOST'] = original
  end

  def test_ensure_available_passes_when_daemon_reachable
    skip 'ollama daemon not reachable' unless ollama_reachable?
    assert_nothing_raised do
      CloudKnowledgeDb::OllamaRunner.ensure_available!
    end
  end

  private

  def ollama_reachable?
    require 'net/http'
    uri = URI.join(CloudKnowledgeDb::OllamaRunner.host, '/api/tags')
    Net::HTTP.get_response(uri).is_a?(Net::HTTPSuccess)
  rescue StandardError
    false
  end
end
