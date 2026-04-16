# CLAUDE.md — cloud-knowledge-db

## Project Overview

Orchestrator for daily ingestion of AWS / Google Cloud / Google Workspace / GitLab official blogs into SQLite, esa, and chiebukuro-mcp.

- **Language:** Ruby 4.0 (CRuby — Python absolutely prohibited)
- **DB:** SQLite3 + sqlite-vec (FTS5 trigram + vec0 768-dim) — reuses `ruby-knowledge-store`
- **Translation:** Anthropic SDK direct call (not Claude CLI) — Haiku for translation/classification, Opus for summarization
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
| `lib/cloud_knowledge_db/orchestrator.rb` | Full-source fetch→translate→import→esa orchestration |
| `lib/cloud_knowledge_db/translator.rb` | Anthropic SDK Haiku translation. English system prompt, CLAUDE.md NOT inherited |
| `lib/cloud_knowledge_db/daily_summarizer.rb` | esa post body generation via Anthropic SDK (Opus) |
| `lib/cloud_knowledge_db/content_classifier.rb` | Classmethod article tag classification (Haiku) |
| `lib/cloud_knowledge_db/esa_writer.rb` | esa API posting |
| `lib/cloud_knowledge_db/trunk_bookmark.rb` | Two-stage bookmark management (load/save/mark_started/mark_completed/status/recommended_since_floor) |
| `lib/cloud_knowledge_db/config.rb` (`Config.ensure_write_host!`) | LocalHostName check — blocks writes on unauthorized hosts (no separate host_guard.rb file) |
| `lib/cloud_knowledge_db/model_resolver.rb` | Runtime model resolution via GET /v1/models |
| `lib/cloud_knowledge_db/config.rb` | APP_ENV config load |

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

## Source Values (all 12)

| source value | content | language |
|---|---|---|
| `aws/blogs/news` | AWS News blog (translated) | ja |
| `aws/blogs/news/original` | AWS News blog (original) | en |
| `aws/classmethod` | classmethod AWS articles | ja |
| `gcp/blogs/products` | Google Cloud blog (translated) | ja |
| `gcp/blogs/products/original` | Google Cloud blog (original) | en |
| `gcp/classmethod` | classmethod GCP articles | ja |
| `gws/blogs/all` | Google Workspace blog (translated) | ja |
| `gws/blogs/all/original` | Google Workspace blog (original) | en |
| `gws/classmethod` | classmethod Workspace articles | ja |
| `gitlab/blogs/all` | GitLab blog (translated) | ja |
| `gitlab/blogs/all/original` | GitLab blog (original) | en |
| `gitlab/classmethod` | classmethod GitLab articles | ja |

**Naming convention:** provider is always the top-level prefix (aws/gcp/gws/gitlab).
`WHERE source LIKE 'aws/%'` covers all AWS records (official + classmethod + originals).

---

## Development Rules

### Language & dependencies
- Python (`python3`, `.py`, `pip`) — absolutely prohibited
- Gems are project-local: `bundle config set --local path 'vendor/bundle'`
- All Ruby commands via `bundle exec`

### TDD (t-wada style)
- Red → Green → Refactor in order
- Never delete test files
- No real LLM calls in tests — use `FakeAnthropicClient` stub
- Run tests: `bundle exec rake test`

### git
- Conventional commits style (`feat:` / `fix:` / `test:` / `chore:` / `docs:`)
- Commit messages in English only
- Always include `.claude/` directory contents in commits

### Scope discipline
- Only modify files in scope for the current task
- Out-of-scope changes require user confirmation

---

## 4-Phase Pipeline

```
Phase 1a (fetch)      RSS/ATOM → English MD → tmpdir
         ↓
Phase 1b (translate)  English MD → Haiku → Japanese MD → tmpdir
         ↓
Phase 2a (import)     All MD → SQLite (content_hash idempotent)
         ↓
Phase 2b (esa)        Japanese MD only → esa API (official 4 sources; classmethod skipped)
```

### tmpdir file naming
```
{tmpdir}/2026-04-15-aws-original-{slug}.md   # English original
{tmpdir}/2026-04-15-aws-{slug}.md            # Japanese translation
```

### Idempotency per phase
| Phase | Strategy |
|---|---|
| fetch | Deterministic by since/before interval + published_at filter |
| translate | Skip if translated MD already exists (timestamp check) |
| import | `content_hash` UNIQUE INDEX — duplicates auto-skipped |
| esa | Deterministic full path — same name triggers `(1)` duplicate detection |

---

## Rake Tasks

```bash
# Daily (auto SINCE/BEFORE from bookmark)
APP_ENV=production bundle exec rake daily

# Phase-by-phase per source
APP_ENV=test SINCE=2026-04-15 BEFORE=2026-04-16 bundle exec rake fetch:aws
APP_ENV=test DIR=$DIR bundle exec rake translate:aws
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
| production | `~/Library/.../chiebukuro-mcp/db/cloud_knowledge.db` (iCloud) | `bash-trunk-changes` | false | `production/cloud-trunk-changes/` |

---

## CLAUDE.md Contamination Guard

`Translator` and `DailySummarizer` call the Anthropic SDK **directly** (not Claude CLI) so `~/CLAUDE.md` persona instructions are never inherited.

```ruby
class Translator
  SYSTEM_PROMPT = <<~EN
    You are a precise English-to-Japanese translator for cloud platform technical blog articles.
    Translate the provided article to natural Japanese suitable for engineers.
    Rules:
      - Preserve all code blocks, URLs, product names, and technical terms verbatim.
      - Use formal-but-casual technical style (です/ます). Do NOT use slang or dialects.
      - Output ONLY the translation. Do not add explanations or meta commentary.
  EN
end
```

Key points:
- `system` is English-only (no persona leakage from `~/CLAUDE.md`)
- `cache_control: { type: "ephemeral" }` on system prompt — enables prompt cache for batch translation
- "Do NOT use slang or dialects" explicitly blocks gyaru/dialect output

### Contamination test markers
```ruby
CONTAMINATION_MARKERS = %w[ピョン チェケラッチョ じゃりんこ ウチ あんさん 質問？ 確認？ 了解。].freeze
```
`test/test_contamination.rb` verifies every system prompt is clean on every run.

---

## Runtime Model Resolution

Short names only in config — actual model IDs resolved at runtime via `GET /v1/models`.

```ruby
# lib/cloud_knowledge_db/model_resolver.rb
FAMILIES = %w[haiku sonnet opus].freeze

def resolve(family)
  return ENV["CLOUD_KB_PIN_#{family.upcase}"] if ENV["CLOUD_KB_PIN_#{family.upcase}"]
  @cache[family] ||= fetch_latest(family)   # selects max version_tuple from /v1/models
end
```

| Role | Class | Short name |
|---|---|---|
| EN→JA translation | `Translator` | haiku |
| Article tag classification | `ContentClassifier` | haiku |
| Daily esa summary | `DailySummarizer` | opus |
| Default | — | sonnet |

**Escape hatch:** `CLOUD_KB_PIN_HAIKU=claude-haiku-4-5-20251001` pins a specific model ID.

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
    translator:       claude-haiku-4-5-20251001
    daily_summarizer: claude-opus-4-6
```

- `last_started_before > last_completed_before` → WIP (previous run did not complete)
- FLOOR = `min(last_completed_before)` across all sources — safe restart point
- `content_hash` idempotency means safe to re-run from FLOOR

---

## Host Guard

Write tasks (`rake daily`, `fetch:*`, `translate:*`, `import:*`, `esa:*`) check `scutil --get LocalHostName` against `config/environments/production.yml`:

```yaml
allowed_write_host: MacBook-Air-M3
```

Override with `ALLOW_WRITE=1` (escape hatch for exceptional cases).

---

## 1-Article-2-Records Design

Each article produces exactly 2 DB records:

| Record | source example | content |
|---|---|---|
| Translated | `aws/blogs/news` | Japanese translation (Haiku) |
| Original | `aws/blogs/news/original` | English original |

Both records receive embeddings (supports both Japanese and English queries).
Records linked by `url` field in YAML frontmatter.

**classmethod articles:** Japanese original only — no `/original` suffix, no translation, no esa post.

---

## chiebukuro-mcp Integration

Entry in `~/chiebukuro-mcp/chiebukuro.json`:

```json
"cloud_knowledge": {
  "path": "/Users/bash/Library/Mobile Documents/com~apple~CloudDocs/chiebukuro-mcp/db/cloud_knowledge.db",
  "description": "AWS/Google Cloud/Google Workspace/GitLab 公式blog 日次収集 DB。英語原文（source=*/original）と日本語訳（Haiku）を両方格納。",
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

---

## sqlite3 CLI 禁止

システムの `/usr/bin/sqlite3` は vec0 拡張を持たないため `no such module: vec0` エラーになる。
**DB への問い合わせは必ず Ruby + `sqlite_vec` gem 経由で行うこと。**

```ruby
require 'sqlite_vec'   # アンダースコア（ハイフンではない）
```

DB 状態確認は `bundle exec rake db:stats` を使用する。
