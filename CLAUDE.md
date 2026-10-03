# CLAUDE.md — cloud-knowledge-db

## Overview

Orchestrator for daily ingestion of AWS / Google Cloud / Google Workspace / GitLab official blogs into SQLite, esa, and chiebukuro-mcp.

- **Language:** Ruby 4.0 (CRuby — Python absolutely prohibited)
- **DB:** SQLite3 + sqlite-vec (FTS5 trigram + vec0 768-dim) — reuses `ruby-knowledge-store` schema unchanged
- **LLM:** local llama-server (llama.cpp, Qwen3.6-35B-A3B IQ2_M on the MBA write host) via the OpenAI-compatible `/v1/chat/completions` for the daily esa summary. No per-article translation at ingest — English rows are stored as-is and the MCP host agent translates on demand at query time (same pattern as `ruby-rdoc-collector`).
- **Test:** test-unit xUnit (t-wada TDD)

## Architecture

```
~/dev/src/github.com/bash0C7/
├── cloud-knowledge-db/   (this repo — orchestrator)
├── cloud-blog-collector/ (adapter gem: RSS/ATOM/WebFetch/Chrome/Classmethod)
└── ruby-knowledge-store/ (Store / Embedder / Migrator)
```

## DB Schema

Reuses `ruby-knowledge-store` schema unchanged. No additions here.

- `memories.embedding` is NULL by design — vectors live in `memories_vec` only.
- `_sqlite_mcp_meta` is populated by `apply_meta_patches.rb` in dotfiles, not this repo.

## Source Values

| source | content | lang |
|---|---|---|
| `aws/blogs/news` | AWS News blog | en |
| `aws/classmethod` | classmethod AWS articles | ja |
| `gcp/blogs/products` | Google Cloud blog | en |
| `gcp/classmethod` | classmethod GCP articles | ja |
| `gws/blogs/all` | Google Workspace blog | en |
| `gws/classmethod` | classmethod Workspace articles | ja |
| `gitlab/blogs/all` | GitLab blog | en |
| `gitlab/classmethod` | classmethod GitLab articles | ja |

Provider is always the top-level prefix (aws / gcp / gws / gitlab). `WHERE source LIKE 'aws/%'` covers official + classmethod. Official rows are English; classmethod rows are Japanese original. Japanese queries against English rows go through semantic search (or a local translation step before FTS).

## 1-Article-1-Record Design

One article = one DB record holding raw source-language content. Embeddings use ruri multilingual (768-dim), so both Japanese and English are queryable semantically. Translation of English content is on-demand at MCP query time — translated copies are never written to the DB. classmethod articles are already Japanese and skip esa posting (DB-only).

## Development Rules

- Python (`python3`, `.py`, `pip`) — absolutely prohibited.
- Gems are project-local: `bundle config set --local path 'vendor/bundle'`. All Ruby via `bundle exec`.
- TDD red → green → refactor. Never delete test files. No real LLM in tests — inject `test/support/fake_runner.rb`'s `FakeRunner` via `instance_variable_set(:@runner, ...)`. Run: `bundle exec rake test`.
- Conventional commits (`feat:` / `fix:` / `test:` / `chore:` / `docs:`) in English. Always include `.claude/` in commits.
- Modify only in-scope files; out-of-scope changes need confirmation.

## 3-Phase Pipeline

```
Phase 1 (fetch)  RSS/ATOM → MD → tmpdir
Phase 2 (import) MD → SQLite (content_hash idempotent)
Phase 3 (esa)    English MDs → local LLM summary → Japanese esa post
                 (official 4 sources only; classmethod skipped)
```

Source threads run in parallel inside `rake daily` with a `Mutex`-guarded bookmark read-modify-write. tmpdir naming: `{tmpdir}/2026-04-15-aws-{slug}.md` (single English article per record).

Idempotency:
- **fetch** — deterministic by `since`/`before` interval + `published_at` filter
- **import** — `content_hash` UNIQUE INDEX auto-skips duplicates
- **esa** — deterministic full path; same name triggers `(1)` duplicate detection

## Rake Tasks

```bash
# Preflight (read-only): list esa base_name conflicts as JSON
APP_ENV=production bundle exec rake plan
APP_ENV=production bundle exec rake plan SINCE=2026-04-29 BEFORE=2026-04-30

# Full daily pipeline (auto SINCE/BEFORE from bookmark)
APP_ENV=production bundle exec rake daily
APP_ENV=production CKDB_FORCE=1 bundle exec rake daily   # bypass esa preflight (see Host Guard)

# Phase-by-phase per source
# Keys: aws, gcp, gws, gitlab, classmethod (classmethod has no esa: task)
APP_ENV=test SINCE=2026-04-15 BEFORE=2026-04-16 bundle exec rake fetch:aws
APP_ENV=test DIR=$DIR bundle exec rake import:aws
APP_ENV=test DIR=$DIR bundle exec rake esa:aws

# DB ops
bundle exec rake db:stats
bundle exec rake db:scan_pollution
bundle exec rake db:scan_contamination
bundle exec rake db:delete_polluted IDS=1,2,3       # host-guarded

# esa ops
bundle exec rake esa:find_duplicates DATE=2026-04-15
bundle exec rake esa:delete IDS=104                 # host-guarded

# Smoke (excluded from CI)
bundle exec rake smoke:rss_endpoints
```

## APP_ENV Matrix

| APP_ENV | DB path | esa team | esa wip | category prefix |
|---|---|---|---|---|
| development (default) | `db/cloud_knowledge_development.db` | `bist` | true | `development/cloud-trunk-changes/` |
| test | `db/cloud_knowledge_test.db` | `bist` | true | `test/cloud-trunk-changes/` |
| production | `db/cloud_knowledge.db` (mirrored to iCloud via `db_copy_to`) | `bash-trunk-changes` | false | `production/cloud-trunk-changes/` |

## LLM Provider Matrix

| Role | Class | Provider | Model |
|---|---|---|---|
| classmethod tag classification | `ContentClassifier` | claude | haiku |
| Daily esa summary | `DailySummarizer` | local_llama | qwen3.6-35b-a3b-iq2m |
| Default | — | claude | sonnet |

Each consumer resolves `(provider, model)` at construction via `Runner.build`. Config lives in `config/environments/<env>.yml` under `models:` — edit that file to swap models, no code change needed.

### llama-server runtime

The local model is served by **llama-server** (Homebrew `llama.cpp`) on the write host (MBA), managed by the `pj-agent-marionette-ma` gem's `llm` CLI — `marionette-ma llm up local` / `down local` / `status`, launchd label `local.llama-server-local`. `rake daily` requires it healthy (verify `GET /health` returns HTTP 200; `LlamaCppRunner.ensure_available!` checks this before any phase runs). A wedged or unreachable server hangs `summarize` until `LlamaCppRunner::READ_TIMEOUT_SEC` (600s); that failure is labelled `esa summarize failed` (not `esa post failed`) so debugging targets the LLM layer. Host is overridable via `LLAMA_SERVER_HOST` (default `http://127.0.0.1:8081`, i.e. MBA-local — the pipeline is designed to complete without depending on the LAN or MBP).

## CLAUDE.md Contamination Guard

- `DailySummarizer` runs on `LlamaCppRunner` (local HTTP) — unaffected by `~/CLAUDE.md`.
- `ContentClassifier` uses `ClaudeRunner` with `chdir: "/tmp"` to keep the project `CLAUDE.md` out of scope.
- Every consumer's `SYSTEM_PROMPT` forbids slang / dialects / persona output.
- Contamination markers and per-consumer prompt checks live in `test/test_contamination.rb` (asserted on every test pass).

## Two-Stage Bookmark

`db/last_run.yml` — two-commit style:

```yaml
aws_blog:
  last_started_at: 2026-04-16T09:00:00+09:00
  last_started_before: 2026-04-16
  last_completed_at: 2026-04-16T09:08:00+09:00
  last_completed_before: 2026-04-16
  models_used:
    daily_summarizer: { provider: local_llama, model: qwen3.6-35b-a3b-iq2m }
last_run:
  status: ok               # ok | aborted | failed
  finished_at: 2026-04-30T09:08:30+09:00
  reason: nil              # short string when aborted/failed (e.g. "esa conflict: 2件")
```

- `last_started_before > last_completed_before` → WIP (previous run incomplete).
- FLOOR = `min(last_completed_before)` across all sources — safe restart point (`content_hash` idempotency makes re-running safe).
- `status: aborted` — esa preflight returned conflicts. Bypass with `CKDB_FORCE=1`.
- `status: failed` — unrecoverable top-level exception (DB lock, DbSyncer failure). Next kick auto-retries via `content_hash` idempotency.

## Host Guard

Write tasks (`rake daily`, `fetch:*`, `import:*`, `esa:*`, `db:delete_polluted`, `esa:delete`) check `scutil --get LocalHostName` against `allowed_write_host` in `config/environments/production.yml` (currently `MacBook-Air-M3`). Override with `ALLOW_WRITE=1`.

`CKDB_FORCE=1` is a separate, independent escape hatch — it bypasses `rake daily`'s esa preflight conflict gate, not the host guard. Use only when intentionally overwriting or suffix-posting despite a known esa conflict.

## DB Sync (production)

On `rake daily` end, production copies the local DB to an iCloud Drive path (`db_copy_to` in `config/environments/production.yml`) so other Macs can consume it read-only via `chiebukuro-mcp`. The single-file copy approach avoids iCloud uploading mid-stream WAL during parallel writes.

The local `db/cloud_knowledge.db` is written by 5 parallel source threads; each thread's `do_import` closes its `Store` in `ensure` to flush WAL back to the main DB. `CloudKnowledgeDb::DbSyncer.sync(source:, destination:)` then runs `PRAGMA wal_checkpoint(TRUNCATE)` to merge and empty the source WAL, deletes stale `.db-wal` / `.db-shm` at the destination, and `FileUtils.cp`s the single `.db` file. iCloud propagates it to other Macs. The write host stays `MacBook-Air-M3` via host guard.

Files: `lib/cloud_knowledge_db/db_syncer.rb`, `Rakefile` `:daily` tail (invoked only when `cfg['db_copy_to']` is set), `test/test_db_syncer.rb`.

## chiebukuro-mcp Integration

- Entry: `~/chiebukuro-mcp/chiebukuro.json` under the `cloud_knowledge` key (points to the iCloud-mirrored `cloud_knowledge.db`).
- meta_patches: `dotfiles/chiebukuro-mcp/chiebukuro-mcp/scripts/meta_patches/cloud_knowledge.yml`.
- This repo owns DB generation and `ruby-knowledge-store` migration application. It does **not** own recipe / clarification_field / column-hint data — those live in dotfiles meta_patches.

## sqlite3 CLI Prohibited

The system `/usr/bin/sqlite3` lacks the vec0 extension and errors with `no such module: vec0`. Always query the DB via Ruby + the `sqlite_vec` gem (underscore, not hyphen):

```ruby
require 'sqlite_vec'
```

For routine state checks use `bundle exec rake db:stats`.
