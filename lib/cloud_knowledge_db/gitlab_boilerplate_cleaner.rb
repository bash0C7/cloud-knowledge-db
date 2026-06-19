# frozen_string_literal: true
require 'digest'

module CloudKnowledgeDb
  # Repairs gitlab/blogs/all rows whose content was ingested with the GitLab
  # site navigation chrome ("CloseTo search repositories...") glued in front of
  # the article body. The chrome always sits before the first "Published on:"
  # line, so cutting there yields the clean article lead. See cloud-blog-collector
  # ArticleEnricher for the fetch-side fix that prevents new rows from carrying it.
  class GitlabBoilerplateCleaner
    PUBLISHED_ON_MARKER = 'Published on:'
    EMBEDDING_MAX_LENGTH = 2000 # mirrors RubyKnowledgeStore::Store

    # Pure: drop everything before the first "Published on:" marker. Returns the
    # content unchanged when the marker is absent or already at the start.
    def self.strip_nav_chrome(content)
      return content if content.nil?
      idx = content.index(PUBLISHED_ON_MARKER)
      return content if idx.nil? || idx.zero?
      content[idx..]
    end

    # @param db [SQLite3::Database] opened with sqlite-vec loaded, results_as_hash off
    # @param embedder responds to #embed(text) -> Array<Float>(768)
    def initialize(db:, embedder:)
      @db = db
      @embedder = embedder
    end

    # Rewrite every row of +source+ whose content carries the nav-chrome prefix.
    # memories has no UPDATE trigger, so FTS is resynced by hand (delete+insert)
    # and the vec embedding is recomputed from the cleaned content.
    # @return [Array<Integer>] ids actually rewritten
    def clean(source:)
      changed = []
      @db.execute('SELECT id, content FROM memories WHERE source = ?', [source]).each do |id, old_content|
        new_content = self.class.strip_nav_chrome(old_content)
        next if new_content == old_content
        rewrite(id, old_content, new_content)
        changed << id
      end
      changed
    end

    private

    def rewrite(id, old_content, new_content)
      new_hash = Digest::SHA256.hexdigest(new_content)
      embedding_text = new_content.length > EMBEDDING_MAX_LENGTH ? new_content[0, EMBEDDING_MAX_LENGTH] : new_content
      embedding_blob = @embedder.embed(embedding_text).pack('f*')
      @db.transaction do
        @db.execute("INSERT INTO memories_fts(memories_fts, rowid, content) VALUES ('delete', ?, ?)", [id, old_content])
        @db.execute('UPDATE memories SET content = ?, content_hash = ? WHERE id = ?', [new_content, new_hash, id])
        @db.execute('INSERT INTO memories_fts(rowid, content) VALUES (?, ?)', [id, new_content])
        @db.execute('UPDATE memories_vec SET embedding = ? WHERE memory_id = ?', [embedding_blob, id])
      end
    end
  end
end
