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
end
