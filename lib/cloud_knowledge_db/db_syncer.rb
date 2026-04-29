# frozen_string_literal: true
require 'fileutils'
require 'sqlite3'

module CloudKnowledgeDb
  module DbSyncer
    # Sync the source SQLite DB to a destination path (typically on iCloud Drive),
    # so that other Macs can read the latest snapshot via iCloud file sync.
    #
    # Steps:
    #   1. Open source and run PRAGMA wal_checkpoint(TRUNCATE) to flush any
    #      in-flight WAL pages into the main DB file and zero out the WAL.
    #   2. Remove stale .db-wal / .db-shm at the destination, so consumers do
    #      not read a half-synced WAL alongside a fresh main DB.
    #   3. Ensure destination directory exists and copy the single .db file.
    def self.sync(source:, destination:)
      db = SQLite3::Database.new(source)
      db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
      db.close

      ['-wal', '-shm'].each do |suffix|
        path = destination + suffix
        File.unlink(path) if File.exist?(path)
      end

      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp(source, destination)
    end
  end
end
