# frozen_string_literal: true
require_relative 'test_helper'
require_relative 'support/fake_runner'
require 'cloud_knowledge_db/translator'

class TranslatorTest < Test::Unit::TestCase
  def setup
    @fake = FakeRunner.new('翻訳された日本語テキスト')
    @translator = CloudKnowledgeDb::Translator.new(provider: 'local_ollama', model: 'gemma4')
    @translator.instance_variable_set(:@runner, @fake)
  end

  def test_translate_returns_text_from_runner
    out = @translator.translate('English article body.')
    assert_equal '翻訳された日本語テキスト', out
  end

  def test_prompt_includes_system_prompt_and_article
    @translator.translate('article body')
    assert_match(/English-to-Japanese translator/, @fake.last_prompt)
    assert_match(/article body/, @fake.last_prompt)
  end

  def test_default_is_local_ollama_gemma4
    t = CloudKnowledgeDb::Translator.new
    r = t.instance_variable_get(:@runner)
    assert_instance_of CloudKnowledgeDb::OllamaRunner, r
    assert_equal 'gemma4', r.instance_variable_get(:@model)
  end
end
