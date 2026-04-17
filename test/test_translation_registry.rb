# frozen_string_literal: true
require_relative 'test_helper'
require 'sqlite3'
require 'cloud_knowledge_db/translation_registry'

class TranslationRegistryTest < Test::Unit::TestCase
  def setup
    @db = SQLite3::Database.new(':memory:')
    @db.execute('CREATE TABLE memories (id INTEGER PRIMARY KEY, content TEXT, source TEXT)')
  end

  def teardown
    @db.close
  end

  def test_returns_false_when_no_record
    registry = CloudKnowledgeDb::TranslationRegistry.new(@db)
    assert_false registry.has_translation?(source: 'aws/blogs/news', url: 'https://example.com/post-a')
  end

  def test_returns_true_when_body_contains_url_for_source
    @db.execute('INSERT INTO memories(content, source) VALUES(?, ?)',
                ['preface https://example.com/post-a body text', 'aws/blogs/news'])
    registry = CloudKnowledgeDb::TranslationRegistry.new(@db)
    assert_true registry.has_translation?(source: 'aws/blogs/news', url: 'https://example.com/post-a')
  end

  def test_source_scope_is_respected
    @db.execute('INSERT INTO memories(content, source) VALUES(?, ?)',
                ['https://example.com/post-a', 'gitlab/blogs/all'])
    registry = CloudKnowledgeDb::TranslationRegistry.new(@db)
    assert_false registry.has_translation?(source: 'aws/blogs/news', url: 'https://example.com/post-a')
  end

  def test_nil_or_empty_url_returns_false
    @db.execute('INSERT INTO memories(content, source) VALUES(?, ?)', ['body', 'aws/blogs/news'])
    registry = CloudKnowledgeDb::TranslationRegistry.new(@db)
    assert_false registry.has_translation?(source: 'aws/blogs/news', url: nil)
    assert_false registry.has_translation?(source: 'aws/blogs/news', url: '')
  end

  def test_nil_db_returns_false
    registry = CloudKnowledgeDb::TranslationRegistry.new(nil)
    assert_false registry.has_translation?(source: 'aws/blogs/news', url: 'https://example.com/post-a')
  end
end
