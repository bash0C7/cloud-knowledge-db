# cloud-knowledge-db

Orchestrator for daily ingestion of cloud platform official blogs into SQLite, esa, and chiebukuro-mcp.

Collects AWS / Google Cloud / Google Workspace official blogs (English) and classmethod.jp explainer articles (Japanese), stores the English originals as-is into SQLite, and posts a per-provider Japanese summary to esa using a local llama.cpp model. On-demand Japanese translation of English rows happens downstream in the MCP host agent (same pattern as `ruby-rdoc-collector`).

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
rbenv local 4.0.9
bundle config set --local path 'vendor/bundle'
bundle install
```

**llama-server** (required for the daily esa summary — managed by the `pj-agent-marionette-ma` gem, not installed per-repo):

```bash
marionette-ma llm status        # confirm the "local" endpoint is healthy
marionette-ma llm up local      # start it if not (idempotent)
```

`DailySummarizer` calls `http://127.0.0.1:8081/v1/chat/completions` (OpenAI-compatible, `chat_template_kwargs: {enable_thinking: false}`). Override the host via `LLAMA_SERVER_HOST=...`. This defaults to the MBA-local endpoint so the daily pipeline completes without the LAN or MBP.

**esa API token** (macOS Keychain):

```bash
security add-generic-password -a "$USER" -s esa-mcp-token -w '<TOKEN>'
```

**claude CLI** (only required if `models.classifier` is pointed at `provider: claude`):

```bash
brew install claude
claude login
```

The current default has translation/summarization on the local llama-server and only `classifier` on claude. The llama-server runs locally, so no `ANTHROPIC_API_KEY` is needed for the daily pipeline.

---

## APP_ENV Matrix

| APP_ENV | DB path | esa team | esa wip | category prefix |
|---|---|---|---|---|
| development (default) | `db/cloud_knowledge_development.db` | `bist` | true | `development/cloud-trunk-changes/` |
| test | `db/cloud_knowledge_test.db` | `bist` | true | `test/cloud-trunk-changes/` |
| production | `db/cloud_knowledge.db` (mirrored to iCloud via `db_copy_to`) | `bash-trunk-changes` | false | `production/cloud-trunk-changes/` |

The production DB write host is gated via `scutil --get LocalHostName`; only `allowed_write_host` in `config/environments/production.yml` may write.

After `rake daily` finishes, `CloudKnowledgeDb::DbSyncer` checkpoints the WAL, drops stale `.db-wal` / `.db-shm` at the destination, and atomic-renames a tmp copy onto `db_copy_to` (iCloud Drive). Other Macs receive the snapshot via iCloud file sync and read it through `chiebukuro-mcp`. See the **DB Sync (production)** section of `CLAUDE.md` for details.

---

## LLM Provider Matrix

Consumers resolve to a `(provider, model)` pair via `CloudKnowledgeDb::Runner.build`.

| Role | Class | Provider | Model |
|---|---|---|---|
| classmethod tag classification | `ContentClassifier` | claude | haiku |
| Daily esa summary | `DailySummarizer` | local_llama | qwen3.6-35b-a3b-iq2m |
| Default | — | claude | sonnet |

Config per environment (`config/environments/<env>.yml`):

```yaml
models:
  classifier:       { provider: claude,      model: haiku }
  daily_summarizer: { provider: local_llama, model: "qwen3.6-35b-a3b-iq2m" }
  default:          { provider: claude,      model: sonnet }
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

### Zero-touch fast path

For ordinary daily runs the router recognises phrases like `daily` / `日々の最新化` / `普段の取り込み` and delegates to `cloud-knowledge-db-run` in **AUTOCONFIRM** mode — no PLAN/CONFIRMED round-trip.

`rake daily` runs an esa preflight (`EsaPreflight.conflicts`) that aborts before any write if a same `category × name` post already exists at esa (bypass with `CKDB_FORCE=1`), executes the per-source parallel fetch / import / esa pipeline with `content_hash` idempotency, records a `last_run: { status: ok | aborted | failed, finished_at:, reason: }` block in `db/last_run.yml`, and posts a macOS notification (`✓ daily ok` / `⚠ daily aborted` / `✗ daily failed`). Failure is recoverable by re-kicking: `content_hash` idempotency prevents double-writes and the preflight gate prevents double esa posts.

---

## Manual Rake Commands

```bash
# Preflight (read-only): list esa base_name conflicts as JSON, no writes
APP_ENV=production bundle exec rake plan
APP_ENV=production bundle exec rake plan SINCE=2026-04-29 BEFORE=2026-04-30

# Full daily pipeline (auto SINCE/BEFORE from bookmark FLOOR)
APP_ENV=production bundle exec rake daily

# Bypass the esa conflict gate (escape hatch — use only when intentional)
APP_ENV=production CKDB_FORCE=1 bundle exec rake daily

# Explicit window (ignores bookmark)
APP_ENV=production SINCE=2026-04-16 BEFORE=2026-04-18 bundle exec rake daily

# Phase-by-phase for one source
APP_ENV=test SINCE=2026-04-15 BEFORE=2026-04-16 bundle exec rake fetch:aws_blog
# => prints DIR=/var/folders/.../cloudkb_aws_blog_...

APP_ENV=test DIR=$DIR bundle exec rake import:aws_blog
APP_ENV=test DIR=$DIR bundle exec rake esa:aws_blog   # no-op for classmethod_blog
```

Source keys: `aws_blog`, `gcp_blog`, `gws_blog`, `classmethod_blog`.

---

## Operations

| Task | Purpose |
|---|---|
| `rake plan` | Read-only esa preflight — emit conflict list as JSON for the daily window |
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
Phase 3 (esa)    English MDs → local LLM one Japanese prose summary per article
                 → concatenated under `# YYYY-MM-DD <PROVIDER> まとめ` → esa API
                 (official 3 sources; classmethod_blog is DB-only)
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
| classmethod.jp | `dev.classmethod.jp/feed/` | classmethod | `{aws,gcp,gws}/classmethod` | ja |

`WHERE source LIKE 'aws/%'` covers all AWS-related records (official English + classmethod Japanese).

### Japanese queries against the English rows

Official blog rows are stored in English only. The ruri multilingual embedder lets `memories_vec` semantic search work for Japanese queries against English content. For FTS5 lexical search, the MCP host agent translates the Japanese query to English before matching, then presents results side-by-side (English content + on-demand Japanese translation). Classmethod rows are already Japanese and do not need this step.

---

## Reference

- chiebukuro-mcp meta patch (recipes, clarification fields, column hints): `dotfiles/chiebukuro-mcp/chiebukuro-mcp/scripts/meta_patches/cloud_knowledge.yml`
