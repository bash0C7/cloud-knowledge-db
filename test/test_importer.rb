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
end
