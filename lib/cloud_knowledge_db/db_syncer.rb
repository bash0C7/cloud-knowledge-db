# frozen_string_literal: true
require 'fileutils'
require 'sqlite3'

module CloudKnowledgeDb
  module DbSyncer
    # Sync the source SQLite DB to a destination path (typically on iCloud Drive),
    # so that other Macs can read the latest snapshot via iCloud file sync.
    #
    # Steps:
    #   1. Open source and run PRAGMA wal_checkpoint(TRUNCATE). If busy=1 some
    #      other reader/writer still holds the WAL — refuse to copy, since the
    #      resulting destination would silently omit data still in the WAL.
    #   2. Remove stale .db-wal / .db-shm at the destination, so consumers do
    #      not read a half-synced WAL alongside a fresh main DB.
    #   3. Copy to a sibling tmpfile in the destination directory and rename
    #      onto the final path. POSIX rename gives readers an atomic flip
    #      between old and new — they never observe a half-written .db.
    def self.sync(source:, destination:)
      db = SQLite3::Database.new(source)
      begin
        result = db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        busy = result.dig(0, 0).to_i
        unless busy.zero?
          raise "wal_checkpoint(TRUNCATE) busy: another connection holds the WAL (result=#{result.inspect})"
        end
      ensure
        db.close
      end

      ['-wal', '-shm'].each do |suffix|
        path = destination + suffix
        File.unlink(path) if File.exist?(path)
      end

      FileUtils.mkdir_p(File.dirname(destination))
      tmp = "#{destination}.tmp.#{Process.pid}"
      FileUtils.cp(source, tmp)
      File.rename(tmp, destination)
    end
  end
end
