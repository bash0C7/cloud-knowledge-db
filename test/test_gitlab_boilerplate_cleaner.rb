# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/gitlab_boilerplate_cleaner'
require 'ruby_knowledge_store'
require 'sqlite3'
require 'sqlite_vec'
require 'digest'
require 'tmpdir'

class GitlabBoilerplateCleanerTest < Test::Unit::TestCase
  C = CloudKnowledgeDb::GitlabBoilerplateCleaner

  # Deterministic 768-dim embedder: same text -> same vector, different text ->
  # different vector. Lets a test assert the embedding actually changed.
  class FakeEmbedder
    def embed(text)
      h = Digest::SHA256.hexdigest(text)
      Array.new(768) { |i| (h[i % h.length].ord % 97) / 97.0 }
    end
  end

  DIRTY = 'CloseTo search repositories and projects, login to gitlab.com. ' \
          'SuggestionsGitLab Duo Agent PlatformCI/CDWhy GitLab?' \
          'Published on: June 18, 20264 min readOne vulnerability view about scanner coverage.'
  STRIPPED = 'Published on: June 18, 20264 min readOne vulnerability view about scanner coverage.'
  CLEAN = 'Published on: June 1, 2026 an already clean gitlab post with no nav chrome prefix.'
  OTHER = 'An AWS English article body, different source, no published marker at all here.'

  def with_seeded_db
    Dir.mktmpdir do |dir|
      db_path = File.join(dir, 'test.db')
      RubyKnowledgeStore::Migrator.new(db_path, migrations_dir: RubyKnowledgeStore::MIGRATIONS_DIR).run
      embedder = FakeEmbedder.new
      store = RubyKnowledgeStore::Store.new(db_path, embedder: embedder)
      ids = {
        dirty: store.store(DIRTY, source: 'gitlab/blogs/all'),
        clean: store.store(CLEAN, source: 'gitlab/blogs/all'),
        other: store.store(OTHER, source: 'aws/blogs/news')
      }
      store.close

      db = SQLite3::Database.new(db_path)
      db.enable_load_extension(true)
      SqliteVec.load(db)
      db.enable_load_extension(false)
      begin
        yield(db, ids, embedder)
      ensure
        db.close
      end
    end
  end

  # ---- clean (DB rebuild: content / hash / FTS / vec) ----

  def test_clean_rewrites_dirty_row_content_and_hash
    with_seeded_db do |db, ids, _embedder|
      C.new(db: db, embedder: FakeEmbedder.new).clean(source: 'gitlab/blogs/all')
      content, hash = db.execute('SELECT content, content_hash FROM memories WHERE id = ?', [ids[:dirty]]).first
      assert_equal(STRIPPED, content)
      assert_equal(Digest::SHA256.hexdigest(STRIPPED), hash)
    end
  end

  def test_clean_resyncs_fts_so_nav_chrome_no_longer_matches
    with_seeded_db do |db, ids, _embedder|
      C.new(db: db, embedder: FakeEmbedder.new).clean(source: 'gitlab/blogs/all')
      chrome_hits = db.execute("SELECT rowid FROM memories_fts WHERE memories_fts MATCH 'repositories'").flatten
      assert_equal([], chrome_hits, 'nav chrome must no longer be FTS-searchable')
      body_hits = db.execute("SELECT rowid FROM memories_fts WHERE memories_fts MATCH 'vulnerability'").flatten
      assert_equal([ids[:dirty]], body_hits, 'article body must still be FTS-searchable')
    end
  end

  def test_clean_recomputes_embedding_for_rewritten_row
    with_seeded_db do |db, ids, _embedder|
      C.new(db: db, embedder: FakeEmbedder.new).clean(source: 'gitlab/blogs/all')
      stored = db.get_first_value('SELECT embedding FROM memories_vec WHERE memory_id = ?', [ids[:dirty]])
      expected = FakeEmbedder.new.embed(STRIPPED).pack('f*')
      assert_equal(expected, stored, 'embedding must be recomputed from the stripped content')
    end
  end

  def test_clean_leaves_already_clean_and_other_source_rows_untouched
    with_seeded_db do |db, ids, _embedder|
      before_clean = db.execute('SELECT content, content_hash FROM memories WHERE id = ?', [ids[:clean]]).first
      before_other = db.execute('SELECT content, content_hash FROM memories WHERE id = ?', [ids[:other]]).first
      C.new(db: db, embedder: FakeEmbedder.new).clean(source: 'gitlab/blogs/all')
      assert_equal(before_clean, db.execute('SELECT content, content_hash FROM memories WHERE id = ?', [ids[:clean]]).first)
      assert_equal(before_other, db.execute('SELECT content, content_hash FROM memories WHERE id = ?', [ids[:other]]).first)
    end
  end

  def test_clean_returns_only_the_rewritten_ids
    with_seeded_db do |db, ids, _embedder|
      changed = C.new(db: db, embedder: FakeEmbedder.new).clean(source: 'gitlab/blogs/all')
      assert_equal([ids[:dirty]], changed)
    end
  end

  # ---- strip_nav_chrome (pure function) ----

  def test_strip_removes_nav_chrome_prefix_before_first_published_on
    content = 'CloseTo search repositories and projects, login to gitlab.com. ' \
              'SuggestionsGitLab Duo Agent PlatformCI/CDWhy GitLab?' \
              'Published on: June 18, 20264 min readOne vulnerability view: the real body.'
    out = C.strip_nav_chrome(content)
    assert_equal('Published on: June 18, 20264 min readOne vulnerability view: the real body.', out)
  end

  def test_strip_leaves_content_already_starting_with_published_on
    content = 'Published on: June 18, 2026 already clean article lead.'
    assert_equal(content, C.strip_nav_chrome(content))
  end

  def test_strip_leaves_content_without_published_on_marker
    content = 'GitLab 19.1 patch release notes, a clean post with no Published on line.'
    assert_equal(content, C.strip_nav_chrome(content))
  end

  def test_strip_returns_nil_unchanged
    assert_nil(C.strip_nav_chrome(nil))
  end
end
