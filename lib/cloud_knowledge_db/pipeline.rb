# frozen_string_literal: true
require_relative 'trunk_bookmark'
require_relative 'esa_preflight'

module CloudKnowledgeDb
  module Pipeline
    module_function

    # Runs pre-flight checks and marks all sources as started.
    # preflight: is injectable for testing (default hits esa API).
    # Returns { status: :ok } or { status: :aborted, conflicts: [...] }.
    def start(cfg:, bookmark_path:, since:, before:,
              preflight: ->(cfg:, since:, before:) {
                EsaPreflight.conflicts(
                  cfg: cfg, since: since, before: before,
                  searcher: EsaPreflight::DefaultSearcher.new
                )
              })
      conflicts = preflight.call(cfg: cfg, since: since, before: before)
      return { status: :aborted, conflicts: conflicts } \
        unless conflicts.empty? || ENV['CKDB_FORCE'] == '1'

      d = TrunkBookmark.load(bookmark_path)
      cfg['sources'].keys.each { |k| d = TrunkBookmark.mark_started(d, k, before: before) }
      TrunkBookmark.save(bookmark_path, d)
      { status: :ok }
    end

    # Marks completed sources in the bookmark and returns the run status hash.
    # Does NOT write last_run status, sync DB, or notify — those are caller's job.
    def finish(cfg:, bookmark_path:, completed:, failed:, since:, before:)
      d          = TrunkBookmark.load(bookmark_path)
      model_meta = cfg.dig('models', 'daily_summarizer')
      completed.each do |k|
        d = TrunkBookmark.mark_completed(d, k, before: before,
              models_used: { 'daily_summarizer' => model_meta })
      end
      TrunkBookmark.save(bookmark_path, d)
      status = failed.empty? ? 'ok' : 'partial_failed'
      reason = failed.empty? ? nil : "failed sources: #{failed.join(',')}"
      { status: status, reason: reason }
    end
  end
end
