# frozen_string_literal: true
require_relative 'test_helper'
require_relative 'support/fake_anthropic_client'
require 'cloud_knowledge_db/translator'

class TranslatorTest < Test::Unit::TestCase
  class FixedResolver
    def resolve(_); 'claude-haiku-4-5-fixture'; end
  end

  def setup
    @client = FakeAnthropicClient.new(responses: ['翻訳された日本語テキスト'])
    @translator = CloudKnowledgeDb::Translator.new(client: @client, model_resolver: FixedResolver.new)
  end

  def test_translate_returns_text_from_client
    out = @translator.translate('English article body.')
    assert_equal '翻訳された日本語テキスト', out
  end

  def test_passes_haiku_model_id
    @translator.translate('hello')
    assert_equal 'claude-haiku-4-5-fixture', @client.calls.first[:model]
  end

  def test_uses_english_system_prompt_with_cache_control
    @translator.translate('hello')
    sys = @client.calls.first[:system]
    assert_kind_of Array, sys
    assert_match(/English-to-Japanese translator/, sys.first[:text])
    assert_equal 'ephemeral', sys.first[:cache_control][:type]
  end

  def test_user_message_is_the_article
    @translator.translate('article body')
    msg = @client.calls.first[:messages].first
    assert_equal 'user',         msg[:role]
    assert_equal 'article body', msg[:content]
  end
end
