# cloud-knowledge-db

Orchestrator for daily ingestion of cloud platform official blogs into SQLite, esa, and chiebukuro-mcp.

Collects AWS / Google Cloud / Google Workspace / GitLab official blogs (English), translates via Haiku API, stores into SQLite, posts daily summaries to esa, and makes them queryable via chiebukuro-mcp dialogue.

---

## Architecture

```
~/dev/src/github.com/bash0C7/
├── cloud-knowledge-db/         (orchestrator — this repo)
├── cloud-blog-collector/       (adapter gem: RSS/ATOM/WebFetch/Chrome/Classmethod)
└── ruby-knowledge-store/       (existing, reused: Store/Embedder/Migrator)
```

`cloud-knowledge-db` owns execution orchestration only. `cloud-blog-collector` owns fetching. `ruby-knowledge-store` owns persistence.

---

## Setup

```bash
rbenv local 4.0.1
bundle config set --local path 'vendor/bundle'
bundle install
```

**esa API token** (macOS Keychain):
```bash
security add-generic-password -a "$USER" -s esa-mcp-token -w '<TOKEN>'
```

LLM calls (Translator / DailySummarizer / ContentClassifier) go through the `claude` CLI in a `/tmp` cwd, so no `ANTHROPIC_API_KEY` is needed — the CLI handles auth. Install `claude` and sign in before running the pipeline.

---

## APP_ENV Matrix

| APP_ENV | DB path | esa team | esa wip | category prefix |
|---|---|---|---|---|
| development (default) | `db/cloud_knowledge_development.db` | `bist` | true | `development/cloud-trunk-changes/` |
| test | `db/cloud_knowledge_test.db` | `bist` | true | `test/cloud-trunk-changes/` |
| production | `~/Library/.../chiebukuro-mcp/db/cloud_knowledge.db` (iCloud) | `bash-trunk-changes` | false | `production/cloud-trunk-changes/` |

---

## Daily Usage

Run the project-private slash command from within the repo:

```
/cloud-knowledge-db-daily
```

Flow:
1. **PLAN** — reads `db/last_run.yml`, calculates FLOOR/WIP, outputs recommended `CONFIRMED` token
2. **CONFIRMED SINCE=YYYY-MM-DD BEFORE=YYYY-MM-DD** — user confirms date range
3. **EXECUTE** — runs `rake daily`, then `scan_pollution`, `scan_contamination`, `esa:find_duplicates`

---

## Manual Rake Commands

```bash
# Full daily pipeline (auto SINCE/BEFORE from bookmark)
APP_ENV=production bundle exec rake daily

# Phase-by-phase for one source
APP_ENV=test SINCE=2026-04-15 BEFORE=2026-04-16 bundle exec rake fetch:aws
# => DIR=/var/folders/.../aws_..._2026-04-15_2026-04-16

APP_ENV=test DIR=$DIR bundle exec rake translate:aws
APP_ENV=test DIR=$DIR bundle exec rake import:aws
APP_ENV=test DIR=$DIR bundle exec rake esa:aws   # skipped for classmethod
```

---

## Operations

| Task | Purpose |
|---|---|
| `rake db:stats` | Show row counts per source and vector total |
| `rake db:scan_pollution` | Detect empty-meta markers, near-duplicate candidates |
| `rake db:scan_contamination` | Detect CLAUDE.md persona leakage in stored content |
| `rake db:delete_polluted IDS=...` | Hard-delete by explicit ID list (host guard active) |
| `rake esa:find_duplicates [DATE=...]` | Find same-name/same-category duplicate esa posts |
| `rake esa:delete IDS=...` | Hard-delete esa posts by ID list (host guard active) |
| `rake smoke:rss_endpoints` | HEAD check all RSS/ATOM feed URLs (excluded from CI) |

---

## 4-Phase Pipeline

```
Phase 1a (fetch)      RSS/ATOM feed → English MD files → tmpdir
         ↓
Phase 1b (translate)  English MD → Haiku API → Japanese MD → tmpdir
         ↓
Phase 2a (import)     All MD → SQLite (content_hash idempotent)
         ↓
Phase 2b (esa)        Japanese MD only → esa API (official 4 sources only)
```

classmethod articles skip Phase 2b (DB-only, not posted to esa).

---

## Sources

| Source | feed_url | adapter | source values |
|---|---|---|---|
| AWS News | `aws.amazon.com/blogs/aws/feed/` | rss | `aws/blogs/news`, `aws/blogs/news/original` |
| Google Cloud | `cloudblog.withgoogle.com/products/gcp/rss/` | rss | `gcp/blogs/products`, `gcp/blogs/products/original` |
| Google Workspace | `feeds.feedburner.com/GoogleAppsUpdates` | rss | `gws/blogs/all`, `gws/blogs/all/original` |
| GitLab | `about.gitlab.com/atom.xml` | rss | `gitlab/blogs/all`, `gitlab/blogs/all/original` |
| classmethod.jp | `dev.classmethod.jp/feed/` | classmethod | `{aws,gcp,gws,gitlab}/classmethod` |

`WHERE source LIKE 'aws/%'` covers all AWS-related records (official + classmethod + originals).

---

## Reference

Design spec: [`docs/superpowers/specs/2026-04-16-cloud-knowledge-db-design.md`](docs/superpowers/specs/2026-04-16-cloud-knowledge-db-design.md)
