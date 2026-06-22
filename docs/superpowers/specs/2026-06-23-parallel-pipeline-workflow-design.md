# Parallel Pipeline Workflow Design

Replace Ruby-thread parallelism in `rake daily` with Claude workflow-level parallelism and per-source rake tasks. Add explicit model settings to all subagents.

## Problem

`rake daily` spawns 5 Ruby threads sharing a `Mutex` for bookmark writes. This is fragile and keeps all source output in one `cloud-knowledge-db-run` agent context window. Context grows large on a full daily run; partial failures are hard to isolate.

## Goal

- Parallelism at the Claude agent layer, not the Ruby thread layer
- Each source's output lives in its own small agent context
- Intermediate results stay in workflow script variables (not the main session context)
- Failed sources are isolated and independently retriable
- Orchestration is codified as a saveable, resumable workflow script

## Phase 1 — Model Settings

Two agent files are missing explicit `model:` declarations and inherit whatever the session uses.

| Agent file | Change | Reason |
|---|---|---|
| `cloud-knowledge-db-inspect.md` | add `model: haiku` | Read-only rake commands; no judgment required |
| `cloud-knowledge-db-run.md` | add `model: sonnet` | Interprets rake output; needs moderate reasoning |
| `cloud-knowledge-db-pollution-triage.md` | already `model: opus` | Judgment-heavy; no change |
| `cloud-knowledge-db-source-health.md` | already `model: sonnet` | No change |

## Phase 2 — New Rake Tasks and Workflow Script

### New rake tasks (`pipeline:` namespace)

**`rake pipeline:start SINCE=YYYY-MM-DD BEFORE=YYYY-MM-DD`**

Pre-flight before any source runs. Single process, single YAML write.

1. `Config.ensure_write_host!`
2. `OllamaRunner.ensure_available!`
3. `EsaPreflight.conflicts` — exits 1 (status: aborted) if conflicts and `CKDB_FORCE != '1'`
4. `TrunkBookmark.mark_started` for **all** sources in one atomic write to `last_run.yml`
5. Prints JSON: `{"status":"ok","since":"...","before":"..."}`

**`rake pipeline:source SOURCE=aws SINCE=YYYY-MM-DD BEFORE=YYYY-MM-DD`**

Runs one source's full pipeline sequentially. No bookmark writes.

1. `do_fetch(key, since:, before:)` → `dir`
2. `do_import(key, dir:)`
3. `do_esa(key, dir:)` (skipped for classmethod)
4. Exit 0 on success, exit 1 on failure with error message to stderr

**`rake pipeline:finish COMPLETED=aws,gcp,gws FAILED=gitlab SINCE=... BEFORE=...`**

Post-flight after all sources report. Single process, single YAML write.

1. `TrunkBookmark.mark_completed` for each source in `COMPLETED`
2. `record_run('ok')` or `record_run('partial_failed')` depending on whether `FAILED` is empty
3. `DbSyncer.sync` (if `db_copy_to` configured)
4. `Notifier.notify`

### `rake daily` refactor

Replace `Mutex + Thread.new` loop with a sequential `cfg['sources'].keys.each` loop calling the same `do_fetch` / `do_import` / `do_esa` methods. Bookmark logic stays identical (single process, no mutex needed). This is the Ruby-only fallback path; Claude parallelism lives in the workflow layer.

### Workflow script — `.claude/workflows/daily-pipeline.js`

Claude writes a JavaScript orchestration script that the workflow runtime executes:

```
Stage 1  inspect agent
         INTENT=last_run → read bookmark → extract SINCE (FLOOR), BEFORE (today)

Stage 2  run agent  (sonnet)
         CONFIRMED TASK=pipeline:start SINCE=... BEFORE=...
         → if aborted: stop workflow, surface conflict details to user

Stage 3  5 parallel run agents  (sonnet each)
         CONFIRMED TASK=pipeline:source SOURCE=aws       SINCE=... BEFORE=...
         CONFIRMED TASK=pipeline:source SOURCE=gcp       SINCE=... BEFORE=...
         CONFIRMED TASK=pipeline:source SOURCE=gws       SINCE=... BEFORE=...
         CONFIRMED TASK=pipeline:source SOURCE=gitlab    SINCE=... BEFORE=...
         CONFIRMED TASK=pipeline:source SOURCE=classmethod SINCE=... BEFORE=...
         → collect exit status per source into COMPLETED / FAILED lists

Stage 4  run agent  (sonnet)
         CONFIRMED TASK=pipeline:finish COMPLETED=... FAILED=... SINCE=... BEFORE=...
```

Intermediate results (SINCE/BEFORE, per-source status) stay in script variables. The main session context receives only the final summary.

The script is saved to `.claude/workflows/daily-pipeline.js` (project-local, committed to repo) and invocable as `/daily-pipeline`.

### Router skill change (daily fast path)

Old fast path: dispatch `cloud-knowledge-db-run` with `AUTOCONFIRM TASK=daily`.

New fast path: trigger `/daily-pipeline` workflow. The router still handles all other intents (inspect, triage, source-health, per-phase) unchanged.

## Context Isolation Outcome

| Layer | Current | After |
|---|---|---|
| Main session | router + user messages | router + user messages (unchanged) |
| Daily orchestration | one run agent accumulates all 5 sources | workflow script variables (not in any Claude context) |
| Per-source | shared thread output | own agent context (~1/5 the size) |
| Failure isolation | one source abort cancels all threads | failed source is independent; others complete |

## Testing

- `test/test_pipeline_tasks.rb` — TDD (red→green→refactor) for the 3 new rake tasks using `FakeRunner` for LLM injection
- Existing tests unchanged; `rake daily` sequential refactor does not change public API
- Contamination markers added to `test/test_contamination.rb` for the new tasks' system prompts

## Files Changed

| File | Change |
|---|---|
| `.claude/agents/cloud-knowledge-db-inspect.md` | add `model: haiku` |
| `.claude/agents/cloud-knowledge-db-run.md` | add `model: sonnet` |
| `.claude/agents/cloud-knowledge-db-run.md` | add `TASK=pipeline:start/source/finish` handling |
| `.claude/commands/cloud-knowledge-db.md` | daily fast path → `/daily-pipeline` |
| `.claude/workflows/daily-pipeline.js` | new workflow script |
| `Rakefile` | add `pipeline:start`, `pipeline:source`, `pipeline:finish`; refactor `rake daily` to sequential |
| `test/test_pipeline_tasks.rb` | new |
| `test/test_contamination.rb` | add markers for new tasks |
