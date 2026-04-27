# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/importer'

class ImporterTest < Test::Unit::TestCase
  def setup
    @importer = CloudKnowledgeDb::Importer.new
  end

  # --- unknown_source? ---

  def test_validate_rejects_unknown_source
    reason = @importer.validate(content: 'hello world', source: 'aws/bogus')
    assert_not_nil reason
    assert_match(/unknown_source/, reason)
  end

  def test_validate_accepts_known_official_source
    reason = @importer.validate(content: 'hello world from aws', source: 'aws/blogs/news')
    assert_nil reason
  end

  def test_validate_accepts_known_classmethod_source
    body = 'これはclassmethodの日本語記事です。' * 10
    reason = @importer.validate(content: body, source: 'aws/classmethod')
    assert_nil reason
  end

  # --- mojibake? ---

  def test_validate_rejects_content_with_replacement_char
    body = "What�s new in Git 2.54.0?"
    reason = @importer.validate(content: body, source: 'gitlab/blogs/all')
    assert_not_nil reason
    assert_match(/mojibake/, reason)
  end

  def test_mojibake_class_method_mirrors_instance
    assert_true CloudKnowledgeDb::Importer.mojibake?("Here�s the deal")
    assert_false CloudKnowledgeDb::Importer.mojibake?('clean ASCII text')
  end

  # --- html_heavy? ---

  def test_validate_rejects_html_heavy_content_above_5pct
    body = '<h3 class="x">Heading</h3>' * 20 + 'a' * 100
    reason = @importer.validate(content: body, source: 'gws/blogs/all')
    assert_not_nil reason
    assert_match(/html_heavy/, reason)
  end

  def test_validate_passes_content_with_minimal_tags
    body = 'This is a paragraph of mostly prose. ' * 30 + '<a href="x">link</a>'
    reason = @importer.validate(content: body, source: 'gws/blogs/all')
    assert_nil reason
  end

  def test_html_heavy_class_method_mirrors_instance
    heavy = '<div>x</div>' * 10
    light = 'plain prose text. ' * 100 + '<a href="x">link</a>'
    assert_true CloudKnowledgeDb::Importer.html_heavy?(heavy)
    assert_false CloudKnowledgeDb::Importer.html_heavy?(light)
  end

  def test_html_heavy_handles_empty_content
    assert_false CloudKnowledgeDb::Importer.html_heavy?('')
    assert_false CloudKnowledgeDb::Importer.html_heavy?(nil)
  end

  def test_html_heavy_detects_tags_with_long_attributes
    long_attr = 'class="' + 'x' * 250 + '"'
    body = "<div #{long_attr}>content</div>" * 5
    assert_true CloudKnowledgeDb::Importer.html_heavy?(body)
  end

  # --- language_mismatch? ---

  def test_validate_rejects_japanese_in_english_source
    body = 'AWSが、Amazon Bedrockを通じてClaude Opus 4.7をローンチしました。' * 5
    reason = @importer.validate(content: body, source: 'aws/blogs/news')
    assert_not_nil reason
    assert_match(/language_mismatch/, reason)
  end

  def test_validate_passes_english_in_english_source
    body = 'AWS announced today that Claude Opus is now available in Amazon Bedrock for production use.' * 3
    reason = @importer.validate(content: body, source: 'aws/blogs/news')
    assert_nil reason
  end

  def test_validate_rejects_english_only_in_japanese_source
    body = 'This is purely English content with no kana characters whatsoever in the body.' * 3
    reason = @importer.validate(content: body, source: 'aws/classmethod')
    assert_not_nil reason
    assert_match(/language_mismatch/, reason)
  end

  def test_language_mismatch_skips_check_for_short_content
    short = 'short'
    assert_false CloudKnowledgeDb::Importer.language_mismatch?(short, 'en')
    assert_false CloudKnowledgeDb::Importer.language_mismatch?(short, 'ja')
  end

  def test_language_mismatch_class_method_mirrors_instance
    en_text = 'This is purely English content with no kana characters at all.' * 3
    ja_text = 'これは日本語の本文で、ひらがなとカタカナがたくさん含まれてます。' * 3
    assert_true  CloudKnowledgeDb::Importer.language_mismatch?(ja_text, 'en')
    assert_false CloudKnowledgeDb::Importer.language_mismatch?(en_text, 'en')
    assert_true  CloudKnowledgeDb::Importer.language_mismatch?(en_text, 'ja')
    assert_false CloudKnowledgeDb::Importer.language_mismatch?(ja_text, 'ja')
  end

  def test_language_mismatch_does_not_count_cjk_punctuation_as_kana
    # English article quoting Japanese punctuation (e.g. screenshot caption,
    # quoted product tagline). CJK punctuation U+3000-U+303F must NOT be
    # treated as kana, otherwise legit English rows get false-positive rejected.
    body = 'AWS announced a new feature called "Bedrock"' * 5 + '、。「」' * 3
    assert_false CloudKnowledgeDb::Importer.language_mismatch?(body, 'en')
  end
end
