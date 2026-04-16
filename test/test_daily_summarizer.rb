# frozen_string_literal: true
require_relative 'test_helper'
require_relative 'support/fake_runner'
require 'cloud_knowledge_db/daily_summarizer'

class DailySummarizerTest < Test::Unit::TestCase
  def setup
    @fake = FakeRunner.new("# 2026-04-15 AWS まとめ\n\n- 記事1")
    @summarizer = CloudKnowledgeDb::DailySummarizer.new(model: 'opus')
    @summarizer.instance_variable_set(:@runner, @fake)
  end

  def test_summarize_returns_markdown
    md = @summarizer.summarize(provider_short: 'aws', date: '2026-04-15', translated_articles: [
      { title: 'Art1', url: 'https://x', body_ja: '本文1' }
    ])
    assert_match(/# 2026-04-15 AWS まとめ/, md)
  end

  def test_prompt_includes_articles
    @summarizer.summarize(provider_short: 'aws', date: '2026-04-15', translated_articles: [{ title: 'T1', url: 'U1', body_ja: 'B1' }])
    assert_match(/T1/, @fake.last_prompt)
    assert_match(/U1/, @fake.last_prompt)
    assert_match(/B1/, @fake.last_prompt)
  end
end
