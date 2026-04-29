# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/db_syncer'
require 'sqlite3'
require 'tmpdir'
require 'fileutils'

class DbSyncerTest < Test::Unit::TestCase
  DS = CloudKnowledgeDb::DbSyncer

  def test_sync_copies_database_contents
    Dir.mktmpdir do |dir|
      src = File.join(dir, 'src.db')
      dst = File.join(dir, 'iCloud_mock', 'dst.db')

      db = SQLite3::Database.new(src)
      db.execute('PRAGMA journal_mode=WAL')
      db.execute('CREATE TABLE memories (id INTEGER PRIMARY KEY, content TEXT)')
      db.execute("INSERT INTO memories (content) VALUES ('hello')")
      db.execute("INSERT INTO memories (content) VALUES ('world')")
      db.close

      DS.sync(source: src, destination: dst)

      assert(File.exist?(dst), 'destination DB must exist')
      dst_db = SQLite3::Database.new(dst)
      count = dst_db.get_first_value('SELECT COUNT(*) FROM memories')
      dst_db.close
      assert_equal(2, count, 'destination must have same row count')
    end
  end

  def test_sync_creates_destination_directory_if_missing
    Dir.mktmpdir do |dir|
      src = File.join(dir, 'src.db')
      dst = File.join(dir, 'nonexistent', 'subdir', 'dst.db')

      db = SQLite3::Database.new(src)
      db.execute('CREATE TABLE memories (id INTEGER PRIMARY KEY)')
      db.close

      DS.sync(source: src, destination: dst)

      assert(File.exist?(dst), 'destination must be created with parent dirs')
    end
  end

  def test_sync_removes_stale_wal_shm_at_destination
    Dir.mktmpdir do |dir|
      src = File.join(dir, 'src.db')
      dst = File.join(dir, 'dst.db')

      File.write(dst,          '')
      File.write(dst + '-wal', 'old wal data')
      File.write(dst + '-shm', 'old shm data')

      db = SQLite3::Database.new(src)
      db.execute('CREATE TABLE memories (id INTEGER PRIMARY KEY, content TEXT)')
      db.execute("INSERT INTO memories (content) VALUES ('fresh')")
      db.close

      DS.sync(source: src, destination: dst)

      assert_false(File.exist?(dst + '-wal'), 'stale -wal at destination must be removed')
      assert_false(File.exist?(dst + '-shm'), 'stale -shm at destination must be removed')

      dst_db = SQLite3::Database.new(dst)
      content = dst_db.get_first_value('SELECT content FROM memories')
      dst_db.close
      assert_equal('fresh', content)
    end
  end

  def test_sync_captures_wal_contents_via_checkpoint
    Dir.mktmpdir do |dir|
      src = File.join(dir, 'src.db')
      dst = File.join(dir, 'dst.db')

      db = SQLite3::Database.new(src)
      db.execute('PRAGMA journal_mode=WAL')
      db.execute('CREATE TABLE memories (id INTEGER PRIMARY KEY, content TEXT)')
      db.execute("INSERT INTO memories (content) VALUES ('one')")
      db.close

      DS.sync(source: src, destination: dst)

      dst_db = SQLite3::Database.new(dst)
      count = dst_db.get_first_value('SELECT COUNT(*) FROM memories')
      dst_db.close
      assert_equal(1, count, 'sync must capture WAL-mode contents at destination')
    end
  end

  def test_sync_does_not_leave_tmp_artifact
    Dir.mktmpdir do |dir|
      src = File.join(dir, 'src.db')
      dst = File.join(dir, 'dst.db')

      db = SQLite3::Database.new(src)
      db.execute('CREATE TABLE memories (id INTEGER PRIMARY KEY)')
      db.close

      DS.sync(source: src, destination: dst)

      stragglers = Dir.glob(File.join(dir, 'dst.db.tmp.*'))
      assert_equal([], stragglers, 'sync must rename tmp away, not leave dst.db.tmp.<pid>')
    end
  end
end
