---
description: Unified entry point for cloud-knowledge-db operations. Routes user intent (daily pipeline / per-phase runs / read-only inspection / cleanup / feed health) to the appropriate subagent after confirming with the user.
---

Unified router for the cloud-knowledge-db project. Use this whenever the user asks for anything scoped to this repo — running the daily blog-ingest pipeline, individual `fetch:*` / `import:*` / `esa:*` phases, inspecting DB state, finding esa duplicates, scanning pollution or CLAUDE.md contamination, checking RSS endpoint health, or cleaning up bad rows / posts.

## Routing targets

- **run-agent** (`cloud-knowledge-db-run`) — any write-side rake task:
  - `rake daily` (default pipeline across all sources: fetch → import → esa per source, in parallel)
  - `rake fetch:<key>` / `import:<key>` / `esa:<key>` (individual phases)
  - `rake db:delete_polluted IDS=...` / `rake esa:delete IDS=...` (destructive cleanup)
  - Uses a `CONFIRMED`-token gate so the main session can relay parameters to the user for approval.
- **inspect-agent** (`cloud-knowledge-db-inspect`) — read-only:
  - `rake -T`, `rake db:stats`, `rake db:scan_pollution`, `rake db:scan_contamination`, `rake esa:find_duplicates`, `rake smoke:rss_endpoints`, `db/last_run.yml` readback, ad-hoc SQL SELECT.
  - No gate — safe to run immediately.
- **pollution-triage** (`cloud-knowledge-db-pollution-triage`) — analysis-only:
  - Takes scan_pollution / scan_contamination output, inspects each candidate row, recommends DELETE / KEEP / INSPECT-MORE.
  - Never executes deletion itself (that's `cloud-knowledge-db-run` with `TASK=db:delete_polluted`).
- **source-health** (`cloud-knowledge-db-source-health`) — weekly feed-liveness check:
  - Hits every feed URL, flags 4xx/5xx / dead feeds, recommends adapter upgrades (RSS → WebFetch → Chrome).
  - Read-only. Never edits `config/sources.yml`.

## Flow

### 1. Always begin by fetching `rake -T`

Run `cd /Users/bash/dev/src/github.com/bash0C7/cloud-knowledge-db && bundle exec rake -T` yourself in the main session (quick, cheap, no side effects). This is the source of truth for what's currently invocable — task sets change as the Rakefile evolves.

Do not cache or assume the task list; re-run every time this command is invoked.

### 2. Parse `$ARGUMENTS` to infer intent

If `$ARGUMENTS` clearly names an operation (e.g. "daily", "rake 走らせて", "db:stats", "aws だけ", "削除して #135", "feed 生きてる？", "tasks 見せて"), skip to step 4 with that intent pre-filled.

If `$ARGUMENTS` is empty or ambiguous, go to step 3.

### 3. Present the semi-dynamic menu

Show the user these choices. The labels are fixed; the bullet points under each are drawn from the current `rake -T` output so new tasks get surfaced automatically.

```
どれにする、質問？

1. 取り込み — パイプライン実行
   - `rake daily`（デフォルト、全 source 並列: fetch → import → esa）
   - `rake fetch:<key>` 個別（<key> は rake -T の fetch:* から選択）
   - `rake import:<key>` / `esa:<key>` 個別（DIR 必須）

2. 確認 — read-only
   - `rake db:stats`（memories / vec / fts 三者一致）
   - `rake db:scan_pollution` / `rake db:scan_contamination`
   - `rake esa:find_duplicates [DATE=...]`
   - `rake smoke:rss_endpoints`（feed HEAD チェック）
   - `db/last_run.yml` bookmark 読み出し
   - 任意の SELECT クエリ

3. 掃除 — 破壊的整理
   - `rake db:delete_polluted IDS=...`
   - `rake esa:delete IDS=...`

4. 分析 — 汚染トリアージ
   - scan_pollution / scan_contamination の出力を見せて DELETE 判断

5. feed 健全性 — 週次
   - 全 source の RSS/ATOM 応答コードを確認

6. rake -T 一覧表示（このまま出力）

7. その他（自由入力）
```

List the current `fetch:*` / `import:*` / `esa:*` task names under each category dynamically from the `rake -T` output — do not hardcode the list.

Ask the user to pick (number or natural language).

### 4. Confirm understanding

Whether intent came from `$ARGUMENTS` (step 2) or the menu (step 3), echo back your interpretation in one or two sentences:

```
→ 「<意図の言い換え>」で進めるピョン、確認？
   （例: rake daily 相当の全パイプラインを昨日分で実行、SINCE/BEFORE は subagent が bookmark から計算）
```

Wait for user approval. If the user adjusts, update and re-confirm.

### 5. Dispatch

Based on the confirmed intent:

| Menu choice | Dispatch target                                                                  |
|-------------|----------------------------------------------------------------------------------|
| 1. 取り込み   | `cloud-knowledge-db-run` subagent (PLAN first, then CONFIRMED on approval)       |
| 2. 確認      | `cloud-knowledge-db-inspect` subagent (direct, no gate)                          |
| 3. 掃除      | `cloud-knowledge-db-run` subagent (TASK=db:delete_polluted or esa:delete, PLAN then CONFIRMED) |
| 4. 分析      | `cloud-knowledge-db-pollution-triage` subagent (analysis only, no delete)        |
| 5. feed健全性 | `cloud-knowledge-db-source-health` subagent (read-only)                          |
| 6. rake -T  | Print the `rake -T` output you already fetched in step 1 — no subagent           |
| 7. その他    | Treat as free-form; re-ask clarification, or route to whichever subagent fits once clarified |

#### For `cloud-knowledge-db-run` dispatches (choices 1 and 3)

First invocation: PLAN mode. Prompt template:

```
TASK=<resolved task> [SINCE=...] [BEFORE=...] [DIR=...] [IDS=...] [APP_ENV=...]
[free-form context from the user]
```

The subagent will compute defaults it needs (SINCE from bookmark FLOOR, BEFORE today, etc.) and report back. Relay its PLAN to the user and ask for confirmation.

Second invocation (on approval): add `CONFIRMED` to the prompt along with the exact parameter values from the PLAN:

```
CONFIRMED TASK=<task> SINCE=<v> BEFORE=<v> [DIR=<v>] [IDS=<v>] [APP_ENV=<v>]
```

#### For `cloud-knowledge-db-inspect` dispatches (choice 2)

One invocation, direct. Prompt template:

```
INTENT=<db:stats|db:scan_pollution|db:scan_contamination|esa:find_duplicates|smoke:rss_endpoints|last_run|free-form SQL>
[additional params: DATE=..., SQL=..., etc.]
```

### 6. Relay the result

When the subagent returns, relay its output back to the user. Keep it concise — avoid re-explaining what the subagent already explained.

## Hard rules

- **Never** execute `rake daily` / `rake fetch:*` / `rake import:*` / `rake esa:*` / `rake db:delete_*` / `rake esa:delete` yourself from the main session — always go through `cloud-knowledge-db-run`.
- **Never** run ad-hoc write queries against `db/cloud_knowledge.db` yourself — delegate to subagents.
- **Never** skip step 4 (confirm understanding). Even when `$ARGUMENTS` is explicit, echo back the interpretation before dispatching.
- **`rake -T` and `rake db:stats`** may be run directly in the main session (both read-only). Anything else: delegate.

User arguments (optional): $ARGUMENTS
