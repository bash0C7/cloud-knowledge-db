# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/translator'

class TranslatorTest < Test::Unit::TestCase
  def setup
    @translator = CloudKnowledgeDb::Translator.new(model: 'haiku')
    # Stub ClaudeRunner#execute to return fixed text
    @translator.instance_variable_get(:@runner).define_singleton_method(:execute) { |_prompt| '翻訳された日本語テキスト' }
  end

  def test_translate_returns_text_from_runner
    out = @translator.translate('English article body.')
    assert_equal '翻訳された日本語テキスト', out
  end

  def test_prompt_includes_system_prompt_and_article
    captured = nil
    @translator.instance_variable_get(:@runner).define_singleton_method(:execute) { |prompt| captured = prompt; 'ok' }
    @translator.translate('article body')
    assert_match(/English-to-Japanese translator/, captured)
    assert_match(/article body/, captured)
  end
end
