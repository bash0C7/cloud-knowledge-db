# frozen_string_literal: true
require_relative 'test_helper'
require_relative 'support/fake_runner'
require 'cloud_knowledge_db/daily_summarizer'

class DailySummarizerTest < Test::Unit::TestCase
  PROSE_FIXTURE = <<~MD.strip
    本日、新機能Xが提供開始されました。既存のAPIから追加コストなしで利用できます。

    対応リージョンはus-east-1を含む主要4リージョンで、今後さらに拡大予定です。
  MD

  def setup
    @fake = FakeRunner.new(PROSE_FIXTURE)
    @summarizer = CloudKnowledgeDb::DailySummarizer.new(provider: 'local_ollama', model: 'gemma4')
    @summarizer.instance_variable_set(:@runner, @fake)
  end

  def test_summarize_returns_markdown_with_programmatic_header
    md = @summarizer.summarize(provider_short: 'aws', date: '2026-04-15', articles: [
      { title: 'Art1', url: 'https://x', body: 'English body 1' }
    ])
    assert_match(/\A# 2026-04-15 AWS まとめ/, md,
                 'header is built by Ruby, not by the LLM, so it must always be in canonical form')
  end

  def test_summarize_renders_one_section_per_article_with_programmatic_link
    md = @summarizer.summarize(provider_short: 'gws', date: '2026-04-15', articles: [
      { title: 'A1', url: 'https://a/1', body: 'body1' },
      { title: 'A2', url: 'https://a/2', body: 'body2' },
      { title: 'A3', url: 'https://a/3', body: 'body3' }
    ])
    assert_match(%r{## \[A1\]\(https://a/1\)}, md)
    assert_match(%r{## \[A2\]\(https://a/2\)}, md)
    assert_match(%r{## \[A3\]\(https://a/3\)}, md)
  end

  def test_each_article_triggers_one_runner_call_with_its_own_body
    prompts = []
    @fake.define_singleton_method(:execute) do |prompt|
      prompts << prompt
      PROSE_FIXTURE
    end
    @summarizer.summarize(provider_short: 'aws', date: '2026-04-15', articles: [
      { title: 'T1', url: 'U1', body: 'BODY_OF_1' },
      { title: 'T2', url: 'U2', body: 'BODY_OF_2' }
    ])
    assert_equal 2, prompts.length, 'one LLM call per article'
    assert_match(/BODY_OF_1/, prompts[0])
    assert_match(/BODY_OF_2/, prompts[1])
  end

  def test_prompt_forbids_english_and_bullets
    @summarizer.summarize(provider_short: 'aws', date: '2026-04-15',
                          articles: [{ title: 'T', url: 'U', body: 'B' }])
    assert_match(/日本語/, @fake.last_prompt)
    assert_match(/英語.*出力してはならない|必ず日本語/, @fake.last_prompt)
    assert_match(/段落形式/, @fake.last_prompt)
    assert_match(/箇条書き.*使わない|箇条書き.*使えない/, @fake.last_prompt)
  end
end
