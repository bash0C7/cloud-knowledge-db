# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/daily_summarizer'

class DailySummarizerTest < Test::Unit::TestCase
  def setup
    @summarizer = CloudKnowledgeDb::DailySummarizer.new(model: 'opus')
    @summarizer.instance_variable_get(:@runner).define_singleton_method(:run) { |_prompt| "# 2026-04-15 AWS まとめ\n\n- 記事1" }
  end

  def test_summarize_returns_markdown
    md = @summarizer.summarize(provider_short: 'aws', date: '2026-04-15', translated_articles: [
      { title: 'Art1', url: 'https://x', body_ja: '本文1' }
    ])
    assert_match(/# 2026-04-15 AWS まとめ/, md)
  end

  def test_prompt_includes_articles
    captured = nil
    @summarizer.instance_variable_get(:@runner).define_singleton_method(:run) { |prompt| captured = prompt; 'ok' }
    @summarizer.summarize(provider_short: 'aws', date: '2026-04-15', translated_articles: [{ title: 'T1', url: 'U1', body_ja: 'B1' }])
    assert_match(/T1/, captured)
    assert_match(/U1/, captured)
    assert_match(/B1/, captured)
  end
end
