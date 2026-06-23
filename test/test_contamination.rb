# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/daily_summarizer'
require 'cloud_knowledge_db/content_classifier'

class ContaminationTest < Test::Unit::TestCase
  CONTAMINATION_MARKERS = %w[ピョン チェケラッチョ じゃりんこ ウチ あんさん 質問？ 確認？ 了解。 提案。 不明。 理解。].freeze

  def test_daily_summarizer_system_prompt_is_clean
    prompt = CloudKnowledgeDb::DailySummarizer::SYSTEM_PROMPT
    CONTAMINATION_MARKERS.each do |m|
      assert_false(prompt.include?(m), "DailySummarizer SYSTEM_PROMPT contains contamination marker: #{m}")
    end
  end

  def test_content_classifier_system_prompt_is_clean
    prompt = CloudKnowledgeDb::ContentClassifier::SYSTEM_PROMPT
    CONTAMINATION_MARKERS.each do |m|
      assert_false(prompt.include?(m), "ContentClassifier SYSTEM_PROMPT contains contamination marker: #{m}")
    end
  end

  def test_pipeline_source_esa_uses_daily_summarizer
    # pipeline:source calls do_esa which instantiates DailySummarizer.
    # Verify DailySummarizer::SYSTEM_PROMPT is still present and clean
    # (guards against future refactor that might inline a bare LLM call).
    assert defined?(CloudKnowledgeDb::DailySummarizer::SYSTEM_PROMPT),
           'DailySummarizer::SYSTEM_PROMPT must exist for pipeline:source esa phase'
    prompt = CloudKnowledgeDb::DailySummarizer::SYSTEM_PROMPT
    CONTAMINATION_MARKERS.each do |m|
      assert_false prompt.include?(m),
                   "pipeline:source esa path: DailySummarizer SYSTEM_PROMPT contains #{m}"
    end
  end
end
