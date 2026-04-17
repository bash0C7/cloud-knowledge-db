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

  def test_unknown_provider_raises
    assert_raise(ArgumentError) do
      CloudKnowledgeDb::Runner.build(provider: 'bogus', model: 'x')
    end
  end
end
