# frozen_string_literal: true
require_relative 'test_helper'
require_relative 'support/fake_anthropic_client'
require 'cloud_knowledge_db/content_classifier'

class ContentClassifierTest < Test::Unit::TestCase
  class FixedResolver
    def resolve(_); 'claude-haiku-fixture'; end
  end

  def setup
    @client = FakeAnthropicClient.new(responses: ['aws'])
    @classifier = CloudKnowledgeDb::ContentClassifier.new(client: @client, model_resolver: FixedResolver.new)
  end

  def test_classify_returns_normalized_provider_label
    label = @classifier.classify(title: 'Lambda新機能', body: '本文', tags: ['AWS', 'Lambda'])
    assert_equal 'aws', label
  end

  def test_uses_haiku_model
    @classifier.classify(title: 't', body: 'b', tags: [])
    assert_equal 'claude-haiku-fixture', @client.calls.first[:model]
  end
end
