# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/translator'
require 'cloud_knowledge_db/daily_summarizer'

class ContaminationTest < Test::Unit::TestCase
  CONTAMINATION_MARKERS = %w[ピョン チェケラッチョ じゃりんこ ウチ あんさん 質問？ 確認？ 了解。 提案。 不明。 理解。].freeze

  def test_translator_system_prompt_is_clean
    prompt = CloudKnowledgeDb::Translator::SYSTEM_PROMPT
    CONTAMINATION_MARKERS.each do |m|
      assert_false(prompt.include?(m), "Translator SYSTEM_PROMPT contains contamination marker: #{m}")
    end
  end

  def test_daily_summarizer_system_prompt_is_clean
    prompt = CloudKnowledgeDb::DailySummarizer::SYSTEM_PROMPT
    CONTAMINATION_MARKERS.each do |m|
      assert_false(prompt.include?(m), "DailySummarizer SYSTEM_PROMPT contains contamination marker: #{m}")
    end
  end
end
