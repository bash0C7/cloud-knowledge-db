# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/llama_cpp_runner'

class LlamaCppRunnerTest < Test::Unit::TestCase
  def test_initializes_with_model
    runner = CloudKnowledgeDb::LlamaCppRunner.new(model: 'qwen3.6-35b-a3b-iq2m')
    assert_equal 'qwen3.6-35b-a3b-iq2m', runner.instance_variable_get(:@model)
  end

  def test_ensure_available_raises_when_server_unreachable
    original = ENV['LLAMA_SERVER_HOST']
    ENV['LLAMA_SERVER_HOST'] = 'http://127.0.0.1:1'
    assert_raise(RuntimeError) do
      CloudKnowledgeDb::LlamaCppRunner.ensure_available!
    end
  ensure
    ENV['LLAMA_SERVER_HOST'] = original
  end

  def test_ensure_available_passes_when_server_reachable
    omit 'llama-server not reachable' unless llama_server_reachable?
    assert_nothing_raised do
      CloudKnowledgeDb::LlamaCppRunner.ensure_available!
    end
  end

  private

  def llama_server_reachable?
    require 'net/http'
    uri = URI.join(CloudKnowledgeDb::LlamaCppRunner.host, '/health')
    Net::HTTP.get_response(uri).is_a?(Net::HTTPSuccess)
  rescue StandardError
    false
  end
end
