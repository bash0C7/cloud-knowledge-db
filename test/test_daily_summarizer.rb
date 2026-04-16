# frozen_string_literal: true
require_relative 'test_helper'
require_relative 'support/fake_anthropic_client'
require 'cloud_knowledge_db/daily_summarizer'

class DailySummarizerTest < Test::Unit::TestCase
  class FixedResolver
    def resolve(family); "claude-#{family}-fixture"; end
  end

  def setup
    @client = FakeAnthropicClient.new(responses: ["# 2026-04-15 AWS まとめ\n\n- 記事1\n- 記事2"])
    @summarizer = CloudKnowledgeDb::DailySummarizer.new(client: @client, model_resolver: FixedResolver.new)
  end

  def test_summarize_returns_markdown
    md = @summarizer.summarize(provider_short: 'aws', date: '2026-04-15', translated_articles: [
      { title: 'Article 1', url: 'https://x', body_ja: '本文1' },
      { title: 'Article 2', url: 'https://y', body_ja: '本文2' }
    ])
    assert_match(/# 2026-04-15 AWS まとめ/, md)
  end

  def test_uses_opus_model_id
    @summarizer.summarize(provider_short: 'aws', date: '2026-04-15', translated_articles: [])
    assert_equal 'claude-opus-fixture', @client.calls.first[:model]
  end

  def test_user_message_includes_each_article
    @summarizer.summarize(provider_short: 'aws', date: '2026-04-15', translated_articles: [{ title: 'T1', url: 'U1', body_ja: 'B1' }])
    user_content = @client.calls.first[:messages].first[:content]
    assert_match(/T1/, user_content)
    assert_match(/U1/, user_content)
    assert_match(/B1/, user_content)
  end
end
