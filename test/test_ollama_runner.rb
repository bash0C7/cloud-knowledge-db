# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/ollama_runner'

class OllamaRunnerTest < Test::Unit::TestCase
  def test_initializes_with_model
    runner = CloudKnowledgeDb::OllamaRunner.new(model: 'gemma4')
    assert_equal 'gemma4', runner.instance_variable_get(:@model)
  end

  def test_ensure_available_raises_when_ollama_missing
    original_path = ENV['PATH']
    ENV['PATH'] = '/nonexistent-bin-path'
    assert_raise(RuntimeError) do
      CloudKnowledgeDb::OllamaRunner.ensure_available!
    end
  ensure
    ENV['PATH'] = original_path
  end

  def test_ensure_available_passes_when_ollama_present
    # This test only runs when ollama is actually installed locally.
    # If `which ollama` finds nothing, skip instead of failing.
    skip 'ollama not installed on this host' unless system('which ollama > /dev/null 2>&1')
    assert_nothing_raised do
      CloudKnowledgeDb::OllamaRunner.ensure_available!
    end
  end
end
