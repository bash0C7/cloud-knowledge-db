# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/runner'

class RunnerTest < Test::Unit::TestCase
  def test_claude_provider_returns_claude_runner
    r = CloudKnowledgeDb::Runner.build(provider: 'claude', model: 'haiku')
    assert_instance_of CloudKnowledgeDb::ClaudeRunner, r
    assert_equal 'haiku', r.instance_variable_get(:@model)
  end

  def test_local_ollama_provider_returns_ollama_runner
    r = CloudKnowledgeDb::Runner.build(provider: 'local_ollama', model: 'gemma4')
    assert_instance_of CloudKnowledgeDb::OllamaRunner, r
    assert_equal 'gemma4', r.instance_variable_get(:@model)
  end

  def test_local_llama_provider_returns_llama_cpp_runner
    r = CloudKnowledgeDb::Runner.build(provider: 'local_llama', model: 'qwen3.6-35b-a3b-iq2m')
    assert_instance_of CloudKnowledgeDb::LlamaCppRunner, r
    assert_equal 'qwen3.6-35b-a3b-iq2m', r.instance_variable_get(:@model)
  end

  def test_unknown_provider_raises
    assert_raise(ArgumentError) do
      CloudKnowledgeDb::Runner.build(provider: 'bogus', model: 'x')
    end
  end

  def test_ensure_available_dispatches_to_llama_cpp_runner
    original = ENV['LLAMA_SERVER_HOST']
    ENV['LLAMA_SERVER_HOST'] = 'http://127.0.0.1:1'
    assert_raise(RuntimeError) do
      CloudKnowledgeDb::Runner.ensure_available!(provider: 'local_llama')
    end
  ensure
    ENV['LLAMA_SERVER_HOST'] = original
  end

  def test_ensure_available_is_noop_for_claude
    assert_nothing_raised { CloudKnowledgeDb::Runner.ensure_available!(provider: 'claude') }
  end
end
