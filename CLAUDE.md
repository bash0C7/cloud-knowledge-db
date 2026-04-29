# CLAUDE.md — cloud-knowledge-db

## Project Overview

Orchestrator for daily ingestion of AWS / Google Cloud / Google Workspace / GitLab official blogs into SQLite, esa, and chiebukuro-mcp.

- **Language:** Ruby 4.0 (CRuby — Python absolutely prohibited)
- **DB:** SQLite3 + sqlite-vec (FTS5 trigram + vec0 768-dim) — reuses `ruby-knowledge-store`
- **LLM:** Local ollama gemma4 via HTTP `/api/generate` for the daily esa summary. Per-article translation is NOT performed at ingest time — English blog articles are stored as-is and the host MCP agent translates on-demand at query time (same pattern as `ruby-rdoc-collector`).
- **Test:** test-unit xUnit style (t-wada TDD)

---

## Architecture

```
~/dev/src/github.com/bash0C7/
├── cloud-knowledge-db/         (this repo — orchestrator)
├── cloud-blog-collector/       (adapter gem: RSS/ATOM/WebFetch/Chrome/Classmethod)
└── ruby-knowledge-store/       (existing — Store/Embedder/Migrator, schema unchanged)
```

### lib/ responsibilities

| File | Responsibility |
|---|---|
| `lib/cloud_knowledge_db/runner.rb` | Factory `Runner.build(provider:, model:)` returning `ClaudeRunner` or `OllamaRunner` |
| `lib/cloud_knowledge_db/claude_runner.rb` | `claude -p` CLI wrapper (chdir /tmp to block CLAUDE.md contamination) |
| `lib/cloud_knowledge_db/ollama_runner.rb` | Local ollama HTTP client (`/api/generate`, `stream=false`, `think=false`) + `ensure_available!` |
| `lib/cloud_knowledge_db/daily_summarizer.rb` | esa post body generation (takes English articles, emits Japanese summary) |
| `lib/cloud_knowledge_db/content_classifier.rb` | classmethod article tag classification (Claude haiku) |
| `lib/cloud_knowledge_db/esa_writer.rb` | esa API posting |
| `lib/cloud_knowledge_db/trunk_bookmark.rb` | Two-stage bookmark management (load/save/mark_started/mark_completed/status/recommended_since_floor) |
| `lib/cloud_knowledge_db/config.rb` | APP_ENV config load; `Config.ensure_write_host!` gates writes by LocalHostName |
| `lib/cloud_knowledge_db/db_syncer.rb` | `DbSyncer.sync(source:, destination:)` — checkpoint WAL, drop stale wal/shm at destination, atomic rename copy for `db_copy_to` |

---

## DB Schema

Reuses `ruby-knowledge-store` unchanged. No schema additions in this repo.

```sql
CREATE TABLE memories (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  content      TEXT    NOT NULL,
  source       TEXT    NOT NULL,
  content_hash TEXT    NOT NULL UNIQUE,
  embedding    BLOB,
  created_at   TEXT    NOT NULL
);
CREATE VIRTUAL TABLE memories_fts USING fts5(content, content='memories', content_rowid='id', tokenize='trigram');
CREATE VIRTUAL TABLE memories_vec USING vec0(memory_id INTEGER PRIMARY KEY, embedding FLOAT[768]);
-- _sqlite_mcp_meta: populated by apply_meta_patches.rb (dotfiles, not this repo)
```

`memories.embedding` is NULL by design — vectors live in `memories_vec` only.

---

## Source Values (all 8)

| source value | content | language |
|---|---|---|
| `aws/blogs/news` | AWS News blog | en |
| `aws/classmethod` | classmethod AWS articles | ja |
| `gcp/blogs/products` | Google Cloud blog | en |
| `gcp/classmethod` | classmethod GCP articles | ja |
| `gws/blogs/all` | Google Workspace blog | en |
| `gws/classmethod` | classmethod Workspace articles | ja |
| `gitlab/blogs/all` | GitLab blog | en |
| `gitlab/classmethod` | classmethod GitLab articles | ja |

**Naming convention:** provider is always the top-level prefix (aws/gcp/gws/gitlab).
`WHERE source LIKE 'aws/%'` covers all AWS records (official + classmethod).
Official blog rows are English; classmethod rows are Japanese original. Japanese queries against English rows should either be FTS-searched after a local translation step on the agent side, or funnelled through semantic search.

---

## Development Rules

### Language & dependencies
- Python (`python3`, `.py`, `pip`) — absolutely prohibited
- Gems are project-local: `bundle config set --local path 'vendor/bundle'`
- All Ruby commands via `bundle exec`

### TDD (t-wada style)
- Red → Green → Refactor in order
- Never delete test files
- No real LLM calls in tests — inject `test/support/fake_runner.rb`'s `FakeRunner` via `instance_variable_set(:@runner, ...)`
- Run tests: `bundle exec rake test`

### git
- Conventional commits style (`feat:` / `fix:` / `test:` / `chore:` / `docs:`)
- Commit messages in English only
- Always include `.claude/` directory contents in commits

### Scope discipline
- Only modify files in scope for the current task
- Out-of-scope changes require user confirmation

---

## 3-Phase Pipeline

```
Phase 1 (fetch)   RSS/ATOM → English MD (or classmethod Japanese MD) → tmpdir
        ↓
Phase 2 (import)  MD → SQLite (content_hash idempotent)
        ↓
Phase 3 (esa)    English MDs → gemma4 summary → Japanese esa post
                 (official 4 sources; classmethod skipped)
```

Source threads run in parallel inside `rake daily` with per-phase timing logs. See Rakefile for the `Mutex`-guarded bookmark read-modify-write.

### tmpdir file naming
```
{tmpdir}/2026-04-15-aws-{slug}.md   # single English article per record
```

### Idempotency per phase
| Phase | Strategy |
|---|---|
| fetch | Deterministic by since/before interval + published_at filter |
| import | `content_hash` UNIQUE INDEX — duplicates auto-skipped |
| esa | Deterministic full path — same name triggers `(1)` duplicate detection |

---

## Rake Tasks

```bash
# Daily (auto SINCE/BEFORE from bookmark)
APP_ENV=production bundle exec rake daily

# Phase-by-phase per source
APP_ENV=test SINCE=2026-04-15 BEFORE=2026-04-16 bundle exec rake fetch:aws
APP_ENV=test DIR=$DIR bundle exec rake import:aws
APP_ENV=test DIR=$DIR bundle exec rake esa:aws        # skipped for classmethod

# Available source keys: aws, gcp, gws, gitlab, classmethod (no esa: task)

# DB operations
bundle exec rake db:scan_pollution
bundle exec rake db:scan_contamination
bundle exec rake db:delete_polluted IDS=1,2,3         # host guard active
bundle exec rake db:stats

# esa operations
bundle exec rake esa:find_duplicates DATE=2026-04-15
bundle exec rake esa:delete IDS=104                   # host guard active

# Smoke (excluded from CI)
bundle exec rake smoke:rss_endpoints
```

---

## APP_ENV Matrix

| APP_ENV | DB path | esa team | esa wip | category prefix |
|---|---|---|---|---|
| development (default) | `db/cloud_knowledge_development.db` | `bist` | true | `development/cloud-trunk-changes/` |
| test | `db/cloud_knowledge_test.db` | `bist` | true | `test/cloud-trunk-changes/` |
| production | `db/cloud_knowledge.db` → iCloud にミラー (`db_copy_to`) | `bash-trunk-changes` | false | `production/cloud-trunk-changes/` |

---

## CLAUDE.md Contamination Guard

`DailySummarizer` runs on `OllamaRunner` (local HTTP), which is not affected by `~/CLAUDE.md` at all. `ContentClassifier` still uses `ClaudeRunner`, which runs `claude -p` with `chdir: "/tmp"` so the project-level `CLAUDE.md` is out of scope. Every consumer's `SYSTEM_PROMPT` also explicitly forbids slang/dialects/persona output.

### Contamination test markers
```ruby
CONTAMINATION_MARKERS = %w[ピョン チェケラッチョ じゃりんこ ウチ あんさん 質問？ 確認？ 了解。].freeze
```
`test/test_contamination.rb` verifies every consumer's `SYSTEM_PROMPT` is clean on every run.

---

## LLM Provider Matrix

Each consumer resolves to a `(provider, model)` pair at construction via `Runner.build`.

| Role | Class | Provider | Model |
|---|---|---|---|
| classmethod tag classification | `ContentClassifier` | claude | haiku |
| Daily esa summary | `DailySummarizer` | local_ollama | gemma4 |
| Default | — | claude | sonnet |

Config shape per-environment (`config/environments/<env>.yml`):

```yaml
models:
  classifier:       { provider: claude,       model: haiku }
  daily_summarizer: { provider: local_ollama, model: gemma4 }
  default:          { provider: claude,       model: sonnet }
```

To run the summary on a different ollama model, only this file changes; no code edit is needed.

---

## Two-Stage Bookmark

`db/last_run.yml` — two-commit style (same pattern as ruby-knowledge-db):

```yaml
aws_blog:
  last_started_at:       2026-04-16T09:00:00+09:00
  last_started_before:   2026-04-16
  last_completed_at:     2026-04-16T09:08:00+09:00
  last_completed_before: 2026-04-16
  models_used:
    daily_summarizer: { provider: local_ollama, model: gemma4 }
```

- `last_started_before > last_completed_before` → WIP (previous run did not complete)
- FLOOR = `min(last_completed_before)` across all sources — safe restart point
- `content_hash` idempotency means safe to re-run from FLOOR

---

## Host Guard

Write tasks (`rake daily`, `fetch:*`, `import:*`, `esa:*`) check `scutil --get LocalHostName` against `config/environments/production.yml`:

```yaml
allowed_write_host: MacBook-Air-M3
```

Override with `ALLOW_WRITE=1` (escape hatch for exceptional cases).

---

## DB Sync (production)

production 限定で、`rake daily` の最終ステップでローカル DB を iCloud Drive 上の chiebukuro-mcp 参照先にコピーする。`config/environments/production.yml` の `db_copy_to` キーで destination を指定。

### フロー
1. ローカル `db/cloud_knowledge.db` で 5 並列スレッドが fetch / import / esa を実行
2. 各 thread の `do_import` 終端で `ensure { store.close }` → WAL を main DB に書き戻し
3. 全 thread 完了後に `CloudKnowledgeDb::DbSyncer.sync(source:, destination:)` を呼ぶ
   - `PRAGMA wal_checkpoint(TRUNCATE)` で source の WAL を main DB にマージ＋空に
   - destination 側の `.db-wal` / `.db-shm` 残骸を削除
   - `FileUtils.mkdir_p` + `FileUtils.cp` で単一 .db ファイルをコピー
4. iCloud Drive のファイル同期で他 Mac に伝播 → 各端末の `chiebukuro-mcp` が read-only で参照

### この方式を採用した理由
- daily の並列書き込み中に iCloud 同期が WAL を中途半端にアップロードする事故を回避
- 兄弟リポ `ruby-knowledge-db` と同じ `db_copy_to` パターン
- 他 Mac は受け身で iCloud 同期を受けるだけ。書き込みは host guard で `MacBook-Air-M3` 限定

### 実装
- `lib/cloud_knowledge_db/db_syncer.rb` — sync 本体
- `Rakefile` の `:daily` 末尾 — `cfg['db_copy_to']` 設定時のみ呼び出し
- `test/test_db_syncer.rb` — sync 契約のテスト

---

## 1-Article-1-Record Design

Each article produces exactly one DB record holding the raw source-language content:

| Record | source example | content |
|---|---|---|
| English official | `aws/blogs/news` | English original |
| Japanese classmethod | `aws/classmethod` | Japanese original |

The record receives an embedding on ingest (supports both Japanese and English semantic queries via ruri multilingual embedder). On-demand Japanese translation of official blog content is handled downstream by the MCP host agent at query time — the pipeline never writes translated copies to the DB.

**classmethod articles:** already Japanese, no esa post (DB-only).

---

## chiebukuro-mcp Integration

Entry in `~/chiebukuro-mcp/chiebukuro.json`:

```json
"cloud_knowledge": {
  "path": "/Users/bash/Library/Mobile Documents/com~apple~CloudDocs/chiebukuro-mcp/db/cloud_knowledge.db",
  "description": "AWS/Google Cloud/Google Workspace/GitLab 公式blog 日次収集 DB。英語原文のみ格納（日本語訳はMCPホスト側でクエリ時オンデマンド）。classmethod 解説記事は日本語原文で併録。",
  "semantic_search": {
    "vec_table": "memories_vec",
    "content_table": "memories",
    "content_column": "content",
    "source_column": "source",
    "join_key": "memory_id"
  }
}
```

**meta_patches location:** `dotfiles/chiebukuro-mcp/chiebukuro-mcp/scripts/meta_patches/cloud_knowledge.yml`

This repo owns `cloud_knowledge.db` generation and `ruby-knowledge-store` migration application.
This repo does NOT own recipe / clarification_field / column-hint data — that lives in dotfiles meta_patches.

書き込み Mac (`MacBook-Air-M3`) は `db/cloud_knowledge.db` ローカルに書き、`rake daily` 完走時に iCloud 上の参照先へ単一 .db ファイルとしてコピーする。他 Mac は iCloud Drive のファイル同期で受信し、各端末の `chiebukuro-mcp` が read-only で参照。詳細は「## DB Sync (production)」を参照。

---

## sqlite3 CLI 禁止

システムの `/usr/bin/sqlite3` は vec0 拡張を持たないため `no such module: vec0` エラーになる。
**DB への問い合わせは必ず Ruby + `sqlite_vec` gem 経由で行うこと。**

```ruby
require 'sqlite_vec'   # アンダースコア（ハイフンではない）
```

DB 状態確認は `bundle exec rake db:stats` を使用する。
