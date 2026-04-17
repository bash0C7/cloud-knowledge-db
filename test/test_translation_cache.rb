# frozen_string_literal: true
require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'cloud_knowledge_db/translation_cache'

class TranslationCacheTest < Test::Unit::TestCase
  def setup
    @base = Dir.mktmpdir('cachebase_')
    @cache_dir = File.join(@base, 'translated')
  end

  def teardown
    FileUtils.remove_entry(@base) if File.directory?(@base)
  end

  def test_fetch_returns_nil_when_file_missing
    cache = CloudKnowledgeDb::TranslationCache.new(@cache_dir)
    assert_nil cache.fetch('2026-04-16-aws-some-slug.md')
  end

  def test_store_then_fetch_round_trip
    cache = CloudKnowledgeDb::TranslationCache.new(@cache_dir)
    basename = '2026-04-16-aws-some-slug.md'
    cache.store(basename, "---\ntitle: x\n---\nbody\n")
    assert_equal "---\ntitle: x\n---\nbody\n", cache.fetch(basename)
  end

  def test_store_creates_cache_dir_if_absent
    assert_false File.directory?(@cache_dir)
    cache = CloudKnowledgeDb::TranslationCache.new(@cache_dir)
    cache.store('x.md', 'body')
    assert_true File.directory?(@cache_dir)
  end

  def test_fetch_is_source_agnostic
    cache = CloudKnowledgeDb::TranslationCache.new(@cache_dir)
    cache.store('2026-04-16-aws-a.md', 'a')
    assert_equal 'a', cache.fetch('2026-04-16-aws-a.md')
    assert_nil   cache.fetch('2026-04-16-aws-b.md')
  end
end
