# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/content_classifier'

class ContentClassifierTest < Test::Unit::TestCase
  def setup
    @classifier = CloudKnowledgeDb::ContentClassifier.new(model: 'haiku')
    @classifier.instance_variable_get(:@runner).define_singleton_method(:execute) { |_prompt| 'aws' }
  end

  def test_classify_returns_normalized_provider_label
    label = @classifier.classify(title: 'Lambda新機能', body: '本文', tags: ['AWS', 'Lambda'])
    assert_equal 'aws', label
  end

  def test_unknown_label_returns_none
    @classifier.instance_variable_get(:@runner).define_singleton_method(:execute) { |_prompt| 'garbage' }
    label = @classifier.classify(title: 't', body: 'b', tags: [])
    assert_equal 'none', label
  end
end
