# cloud-knowledge-db

Orchestrator for daily ingestion of cloud platform official blogs into SQLite, esa, and chiebukuro-mcp.

Collects AWS / Google Cloud / Google Workspace / GitLab official blogs (English) and classmethod.jp explainer articles (Japanese), stores the English originals as-is into SQLite, and posts a per-provider Japanese summary to esa using a local ollama gemma4 model. On-demand Japanese translation of English rows happens downstream in the MCP host agent (same pattern as `ruby-rdoc-collector`).

---

## Architecture

```
~/dev/src/github.com/bash0C7/
├── cloud-knowledge-db/         (orchestrator — this repo)
├── cloud-blog-collector/       (adapter gem: RSS/ATOM/WebFetch/Chrome/Classmethod + ArticleEnricher)
└── ruby-knowledge-store/       (existing, reused: Store/Embedder/Migrator)
```

`cloud-knowledge-db` owns execution orchestration only. `cloud-blog-collector` owns fetching, including full-article enrichment when RSS delivers only a summary. `ruby-knowledge-store` owns persistence (SQLite3 + sqlite-vec, FTS5 trigram + vec0 768-dim).

---

## Setup

```bash
rbenv local 4.0.1
bundle config set --local path 'vendor/bundle'
bundle install
```

**ollama** (required for the daily esa summary):

```bash
brew install ollama
brew services start ollama        # or: ollama serve
ollama pull gemma4:e2b            # production default, 7.2GB
```

`DailySummarizer` calls `http://localhost:11434/api/generate` with `stream=false, think=false`. Override the host via `OLLAMA_HOST=...`; enable think mode via `OLLAMA_THINK=true` (default `false`; think mode is ~2× slower with no measured quality win on this workload).

**esa API token** (macOS Keychain):

```bash
security add-generic-password -a "$USER" -s esa-mcp-token -w '<TOKEN>'
```

**claude CLI** (only required if `models.classifier` is pointed at `provider: claude`):

```bash
brew install claude
claude login
```

The current default has translation/summarization on local ollama and only `classifier` on claude. Ollama runs locally, so no `ANTHROPIC_API_KEY` is needed for the daily pipeline.

---

## APP_ENV Matrix

| APP_ENV | DB path | esa team | esa wip | category prefix |
|---|---|---|---|---|
| development (default) | `db/cloud_knowledge_development.db` | `bist` | true | `development/cloud-trunk-changes/` |
| test | `db/cloud_knowledge_test.db` | `bist` | true | `test/cloud-trunk-changes/` |
| production | `db/cloud_knowledge.db` → iCloud にミラー (`db_copy_to`) | `bash-trunk-changes` | false | `production/cloud-trunk-changes/` |

The production DB write host is gated via `scutil --get LocalHostName`; only `allowed_write_host` in `config/environments/production.yml` may write.

After `rake daily` finishes, `CloudKnowledgeDb::DbSyncer` checkpoints the WAL, drops stale `.db-wal` / `.db-shm` at the destination, and atomic-renames a tmp copy onto `db_copy_to` (iCloud Drive). Other Macs receive the snapshot via iCloud file sync and read it through `chiebukuro-mcp`. See the **DB Sync (production)** section of `CLAUDE.md` for details.

---

## LLM Provider Matrix

Consumers resolve to a `(provider, model)` pair via `CloudKnowledgeDb::Runner.build`.

| Role | Class | Provider | Model |
|---|---|---|---|
| classmethod tag classification | `ContentClassifier` | claude | haiku |
| Daily esa summary | `DailySummarizer` | local_ollama | gemma4:e2b |
| Default | — | claude | sonnet |

Config per environment (`config/environments/<env>.yml`):

```yaml
models:
  classifier:       { provider: claude,       model: haiku }
  daily_summarizer: { provider: local_ollama, model: "gemma4:e2b" }
  default:          { provider: claude,       model: sonnet }
```

Switching daily_summarizer to claude only requires editing this YAML; no code change.

---

## Daily Usage

Run the project-private slash command from within the repo:

```
/cloud-knowledge-db
```

This is a unified menu router (see `.claude/commands/cloud-knowledge-db.md`). It fetches `rake -T` live, parses your intent, confirms with you, then dispatches to the appropriate subagent:

- `cloud-knowledge-db-run` — write-side `rake daily` / `fetch:*` / `import:*` / `esa:*` / `db:delete_polluted` / `esa:delete` with PLAN/EXECUTE gated on a literal `CONFIRMED` token.
- `cloud-knowledge-db-inspect` — read-only `rake -T` / `db:stats` / `db:scan_pollution` / `db:scan_contamination` / `esa:find_duplicates` / `smoke:rss_endpoints` / `last_run.yml` readback.
- `cloud-knowledge-db-pollution-triage` — analyst over scan output, recommends DELETE/KEEP/INSPECT-MORE per ID (never deletes).
- `cloud-knowledge-db-source-health` — weekly feed-liveness check, recommends adapter upgrades when feeds break.

Typical daily flow: dispatch `/cloud-knowledge-db daily` → subagent returns a PLAN with FLOOR/WIP/SINCE/BEFORE → you approve → subagent runs `rake daily` then post-checks (`db:stats`, `db:scan_pollution`, `db:scan_contamination`, `esa:find_duplicates`).

---

## Manual Rake Commands

```bash
# Full daily pipeline (auto SINCE/BEFORE from bookmark FLOOR)
APP_ENV=production bundle exec rake daily

# Explicit window (ignores bookmark)
APP_ENV=production SINCE=2026-04-16 BEFORE=2026-04-18 bundle exec rake daily

# Phase-by-phase for one source
APP_ENV=test SINCE=2026-04-15 BEFORE=2026-04-16 bundle exec rake fetch:aws_blog
# => prints DIR=/var/folders/.../cloudkb_aws_blog_...

APP_ENV=test DIR=$DIR bundle exec rake import:aws_blog
APP_ENV=test DIR=$DIR bundle exec rake esa:aws_blog   # no-op for classmethod_blog
```

Source keys: `aws_blog`, `gcp_blog`, `gws_blog`, `gitlab_blog`, `classmethod_blog`.

---

## Operations

| Task | Purpose |
|---|---|
| `rake db:stats` | Row counts per source and vector total |
| `rake db:scan_pollution` | Detect empty-meta markers, near-duplicate candidates |
| `rake db:scan_contamination` | Detect `~/CLAUDE.md` gyaru-persona leakage in stored content |
| `rake db:delete_polluted IDS=...` | Hard-delete by explicit ID list (host guard active) |
| `rake esa:find_duplicates [DATE=...]` | Find same-name/same-category duplicate esa posts |
| `rake esa:delete IDS=...` | Hard-delete esa posts by ID list (host guard active, 2s sleep between calls) |
| `rake smoke:rss_endpoints` | HEAD-check every configured feed URL |

---

## 3-Phase Pipeline

```
Phase 1 (fetch)   RSS/ATOM → enriched English MD (or classmethod Japanese MD) → tmpdir
        ↓
Phase 2 (import)  MD → SQLite (content_hash UNIQUE — duplicates auto-skipped)
        ↓
Phase 3 (esa)    English MDs → gemma4 one Japanese prose summary per article
                 → concatenated under `# YYYY-MM-DD <PROVIDER> まとめ` → esa API
                 (official 4 sources; classmethod_blog is DB-only)
```

Sources run in parallel threads inside `rake daily` with per-phase `[timing] ...` logs and an overall `[timing] daily WALLCLOCK` line. A `Mutex`-guarded read-modify-write protects the two-phase `db/last_run.yml` bookmark.

### RSS enrichment

`CloudBlogCollector::ArticleEnricher` hits each item URL via Faraday, parses with oga, strips `script / style / nav / footer / aside / noscript / form`, and extracts the best-matching main-content container (`article → main → [role="main"] → .post-content → .entry-content → .article-body → .blog-post → body`). Feedburner-wrapped Blogger Atom entries get their real blog URL from `<feedburner:origLink>` before enrichment. On any network / parse failure the enricher silently falls back to the original RSS `<description>`.

---

## Sources

| Source | feed_url | adapter | source value | language |
|---|---|---|---|---|
| AWS News | `aws.amazon.com/blogs/aws/feed/` | rss | `aws/blogs/news` | en |
| Google Cloud | `cloudblog.withgoogle.com/products/gcp/rss/` | rss | `gcp/blogs/products` | en |
| Google Workspace | `feeds.feedburner.com/GoogleAppsUpdates` | rss | `gws/blogs/all` | en |
| GitLab | `about.gitlab.com/atom.xml` | rss | `gitlab/blogs/all` | en |
| classmethod.jp | `dev.classmethod.jp/feed/` | classmethod | `{aws,gcp,gws,gitlab}/classmethod` | ja |

`WHERE source LIKE 'aws/%'` covers all AWS-related records (official English + classmethod Japanese).

### Japanese queries against the English rows

Official blog rows are stored in English only. The ruri multilingual embedder lets `memories_vec` semantic search work for Japanese queries against English content. For FTS5 lexical search, the MCP host agent translates the Japanese query to English before matching, then presents results side-by-side (English content + on-demand Japanese translation). Classmethod rows are already Japanese and do not need this step.

---

## Reference

- Design spec: [`docs/superpowers/specs/2026-04-16-cloud-knowledge-db-design.md`](docs/superpowers/specs/2026-04-16-cloud-knowledge-db-design.md)
- chiebukuro-mcp meta patch (recipes, clarification fields, column hints): `dotfiles/chiebukuro-mcp/chiebukuro-mcp/scripts/meta_patches/cloud_knowledge.yml`
