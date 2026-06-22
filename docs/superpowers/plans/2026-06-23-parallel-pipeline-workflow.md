# Parallel Pipeline Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Ruby-thread parallelism in `rake daily` with Claude workflow-level parallelism, three new `pipeline:` rake tasks, and explicit model settings on all subagents.

**Architecture:** A new `CloudKnowledgeDb::Pipeline` module handles pre/post-flight bookmark logic (injectable for testing). Three `pipeline:` rake tasks wrap it as thin shells. A saved Claude workflow script fans out 5 per-source agents in parallel. The router skill's daily path triggers this workflow instead of dispatching a single run agent.

**Tech Stack:** Ruby 4.0 / test-unit / rake / TrunkBookmark / EsaPreflight / `.claude/agents/` / `.claude/workflows/`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `.claude/agents/cloud-knowledge-db-inspect.md` | Modify | Add `model: haiku` |
| `.claude/agents/cloud-knowledge-db-run.md` | Modify | Add `model: sonnet` + pipeline task routing |
| `lib/cloud_knowledge_db/pipeline.rb` | Create | `Pipeline.start` / `Pipeline.finish` bookmark logic |
| `test/test_pipeline_tasks.rb` | Create | Unit tests for Pipeline module |
| `Rakefile` | Modify | Add `pipeline:start`, `pipeline:source`, `pipeline:finish`; make `rake daily` sequential |
| `.claude/workflows/daily-pipeline.js` | Create | Workflow script (Claude-generated) |
| `.claude/commands/cloud-knowledge-db.md` | Modify | Daily fast path → `/daily-pipeline` |
| `test/test_contamination.rb` | Modify | Add pipeline SYSTEM_PROMPT marker check |

---

### Task 1: Add model declarations to agent files

**Files:**
- Modify: `.claude/agents/cloud-knowledge-db-inspect.md`
- Modify: `.claude/agents/cloud-knowledge-db-run.md`

- [ ] **Step 1: Add `model: haiku` to inspect agent frontmatter**

Open `.claude/agents/cloud-knowledge-db-inspect.md`. The frontmatter currently has `name:`, `description:`, `tools:`. Add `model: haiku` between `description:` and `tools:`:

```yaml
---
name: cloud-knowledge-db-inspect
description: Read-only inspection for cloud-knowledge-db — DB stats, pollution/contamination scans, esa duplicate search, RSS endpoint HEAD check, `rake -T` listing, `db/last_run.yml` bookmark readback. Never executes write-side tasks. For pipeline runs or destructive cleanup, use `cloud-knowledge-db-run`.
model: haiku
tools: Bash, Read
---
```

- [ ] **Step 2: Add `model: sonnet` to run agent frontmatter**

Open `.claude/agents/cloud-knowledge-db-run.md`. Add `model: sonnet` the same way:

```yaml
---
name: cloud-knowledge-db-run
description: Execute any write-side rake task for cloud-knowledge-db — the full pipeline (`rake daily`), individual `fetch:*` / `import:*` / `esa:*` phases, or destructive cleanup (`db:delete_polluted`, `esa:delete`). Uses a PLAN / CONFIRMED gate so the main session can confirm date ranges and destructive IDs with the user before execution. For read-only queries (stats, scan, find_duplicates, rake -T), use `cloud-knowledge-db-inspect` instead.
model: sonnet
tools: Bash, Read
---
```

- [ ] **Step 3: Run full test suite**

```bash
APP_ENV=test bundle exec rake test
```

Expected: all existing tests pass (no code changed, only agent config)

- [ ] **Step 4: Commit**

```bash
git add .claude/agents/cloud-knowledge-db-inspect.md .claude/agents/cloud-knowledge-db-run.md
git commit -m "feat(agents): add explicit model declarations (haiku for inspect, sonnet for run)"
```

---

### Task 2: Extract Pipeline module and write unit tests

**Files:**
- Create: `lib/cloud_knowledge_db/pipeline.rb`
- Create: `test/test_pipeline_tasks.rb`

- [ ] **Step 1: Write the failing tests**

Create `test/test_pipeline_tasks.rb`:

```ruby
# frozen_string_literal: true
require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'date'
require 'cloud_knowledge_db/pipeline'
require 'cloud_knowledge_db/trunk_bookmark'

class TestPipelineStart < Test::Unit::TestCase
  def setup
    @dir          = Dir.mktmpdir
    @bookmark     = File.join(@dir, 'last_run.yml')
    @since        = Date.parse('2026-06-22')
    @before       = Date.parse('2026-06-23')
    @cfg = {
      'sources' => {
        'aws_blog' => {}, 'gcp_blog' => {}, 'classmethod_blog' => {}
      },
      'models' => {
        'daily_summarizer' => { 'provider' => 'local_ollama', 'model' => 'gemma4' }
      }
    }
    @no_conflicts  = ->(**) { [] }
    FakeConflict   = Struct.new(:to_h) unless defined?(FakeConflict)
    @has_conflicts = ->(**) { [FakeConflict.new({ base_name: 'Conflict' })] }
  end

  def teardown
    FileUtils.rm_rf(@dir)
    ENV.delete('CKDB_FORCE')
  end

  def test_start_writes_mark_started_for_all_sources
    result = CloudKnowledgeDb::Pipeline.start(
      cfg: @cfg, bookmark_path: @bookmark,
      since: @since, before: @before, preflight: @no_conflicts
    )

    assert_equal :ok, result[:status]
    data = CloudKnowledgeDb::TrunkBookmark.load(@bookmark)
    %w[aws_blog gcp_blog classmethod_blog].each do |key|
      assert_equal @before.to_s, data.dig(key, 'last_started_before'),
                   "#{key}: last_started_before not written"
    end
  end

  def test_start_returns_aborted_when_conflicts_exist
    result = CloudKnowledgeDb::Pipeline.start(
      cfg: @cfg, bookmark_path: @bookmark,
      since: @since, before: @before, preflight: @has_conflicts
    )

    assert_equal :aborted, result[:status]
    assert_not_empty result[:conflicts]
    assert_false File.exist?(@bookmark), 'bookmark must not be written on abort'
  end

  def test_start_ignores_conflicts_when_ckdb_force_set
    ENV['CKDB_FORCE'] = '1'
    result = CloudKnowledgeDb::Pipeline.start(
      cfg: @cfg, bookmark_path: @bookmark,
      since: @since, before: @before, preflight: @has_conflicts
    )

    assert_equal :ok, result[:status]
  end
end

class TestPipelineFinish < Test::Unit::TestCase
  def setup
    @dir      = Dir.mktmpdir
    @bookmark = File.join(@dir, 'last_run.yml')
    @since    = Date.parse('2026-06-22')
    @before   = Date.parse('2026-06-23')
    @cfg = {
      'sources' => {
        'aws_blog' => {}, 'gcp_blog' => {}, 'classmethod_blog' => {}
      },
      'models' => {
        'daily_summarizer' => { 'provider' => 'local_ollama', 'model' => 'gemma4' }
      }
    }
    # Pre-populate bookmark as if pipeline:start already ran
    data = {}
    %w[aws_blog gcp_blog classmethod_blog].each do |k|
      data = CloudKnowledgeDb::TrunkBookmark.mark_started(data, k, before: @before)
    end
    CloudKnowledgeDb::TrunkBookmark.save(@bookmark, data)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_finish_marks_completed_for_successful_sources
    result = CloudKnowledgeDb::Pipeline.finish(
      cfg: @cfg, bookmark_path: @bookmark,
      completed: %w[aws_blog gcp_blog], failed: [],
      since: @since, before: @before
    )

    assert_equal 'ok', result[:status]
    assert_nil result[:reason]
    data = CloudKnowledgeDb::TrunkBookmark.load(@bookmark)
    assert_equal @before.to_s, data.dig('aws_blog',  'last_completed_before')
    assert_equal @before.to_s, data.dig('gcp_blog',  'last_completed_before')
    assert_nil   data.dig('classmethod_blog', 'last_completed_before'),
                 'failed source must not be marked completed'
  end

  def test_finish_status_partial_failed_when_some_sources_failed
    result = CloudKnowledgeDb::Pipeline.finish(
      cfg: @cfg, bookmark_path: @bookmark,
      completed: %w[aws_blog], failed: %w[gcp_blog classmethod_blog],
      since: @since, before: @before
    )

    assert_equal 'partial_failed', result[:status]
    assert_match(/gcp_blog/,        result[:reason])
    assert_match(/classmethod_blog/, result[:reason])
  end

  def test_finish_writes_models_used_for_completed_sources
    result = CloudKnowledgeDb::Pipeline.finish(
      cfg: @cfg, bookmark_path: @bookmark,
      completed: %w[aws_blog], failed: [],
      since: @since, before: @before
    )

    assert_equal 'ok', result[:status]
    data = CloudKnowledgeDb::TrunkBookmark.load(@bookmark)
    assert_equal 'gemma4', data.dig('aws_blog', 'models_used', 'daily_summarizer', 'model')
  end
end
```

- [ ] **Step 2: Run tests — verify they fail**

```bash
APP_ENV=test bundle exec ruby -Ilib -Itest test/test_pipeline_tasks.rb
```

Expected: `LoadError: cannot load such file -- cloud_knowledge_db/pipeline`

- [ ] **Step 3: Create the Pipeline module**

Create `lib/cloud_knowledge_db/pipeline.rb`:

```ruby
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
```

- [ ] **Step 4: Run tests — verify they pass**

```bash
APP_ENV=test bundle exec ruby -Ilib -Itest test/test_pipeline_tasks.rb
```

Expected: 6 tests, 0 failures, 0 errors

- [ ] **Step 5: Run full test suite**

```bash
APP_ENV=test bundle exec rake test
```

Expected: all tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/cloud_knowledge_db/pipeline.rb test/test_pipeline_tasks.rb
git commit -m "feat(pipeline): extract Pipeline module with start/finish; add tests"
```

---

### Task 3: Add pipeline:start, pipeline:source, pipeline:finish rake tasks

**Files:**
- Modify: `Rakefile`

Add a `namespace :pipeline` block to the Rakefile. Place it after the `task :plan` block (around line 50, before the fetch/import/esa per-source tasks).

- [ ] **Step 1: Add the pipeline namespace with all three tasks**

Insert into Rakefile after the closing `end` of `task :plan`:

```ruby
namespace :pipeline do
  desc 'Pre-flight: host/ollama check, esa preflight, mark_started all sources'
  task :start do
    require 'bundler/setup'
    require 'date'
    require 'json'
    require 'ruby_knowledge_store'
    require_relative 'lib/cloud_knowledge_db/pipeline'

    since  = Date.parse(ENV['SINCE']  || raise(ArgumentError, 'SINCE required'))
    before = Date.parse(ENV['BEFORE'] || raise(ArgumentError, 'BEFORE required'))

    CloudKnowledgeDb::Config.ensure_write_host!
    CloudKnowledgeDb::OllamaRunner.ensure_available!

    result = CloudKnowledgeDb::Pipeline.start(
      cfg: cfg, bookmark_path: LAST_RUN_PATH, since: since, before: before
    )

    if result[:status] == :aborted
      record_run('aborted', reason: "esa conflict: #{result[:conflicts].size}件")
      CloudKnowledgeDb::Notifier.notify(status: 'aborted',
        reason: "esa conflict: #{result[:conflicts].size}件")
      abort "=== pipeline:start aborted ===\n" \
            "#{JSON.pretty_generate(result[:conflicts].map(&:to_h))}"
    end

    puts JSON.generate(status: 'ok', since: since.to_s, before: before.to_s)
  end

  desc 'Run fetch→import→esa for one source (no bookmark writes)'
  task :source do
    require 'bundler/setup'
    require 'date'
    require 'cloud_blog_collector'
    require 'tmpdir'
    require 'ruby_knowledge_store'
    require_relative 'lib/cloud_knowledge_db/esa_writer'
    require_relative 'lib/cloud_knowledge_db/esa_naming'
    require_relative 'lib/cloud_knowledge_db/daily_summarizer'

    key    = ENV['SOURCE'] || raise(ArgumentError, 'SOURCE required')
    since  = Date.parse(ENV['SINCE']  || raise(ArgumentError, 'SINCE required')).to_time
    before = Date.parse(ENV['BEFORE'] || raise(ArgumentError, 'BEFORE required')).to_time

    CloudKnowledgeDb::Config.ensure_write_host!
    CloudKnowledgeDb::OllamaRunner.ensure_available!

    t0  = Time.now
    dir = do_fetch(key, since: since, before: before)
    puts "[pipeline:source] #{key} fetch  #{(Time.now - t0).round(2)}s"

    t0 = Time.now
    do_import(key, dir: dir)
    puts "[pipeline:source] #{key} import #{(Time.now - t0).round(2)}s"

    t0 = Time.now
    do_esa(key, dir: dir)
    puts "[pipeline:source] #{key} esa    #{(Time.now - t0).round(2)}s"
  end

  desc 'Post-flight: mark_completed, record_run, db sync, notify'
  task :finish do
    require 'bundler/setup'
    require 'date'
    require_relative 'lib/cloud_knowledge_db/pipeline'
    require_relative 'lib/cloud_knowledge_db/db_syncer'

    since     = Date.parse(ENV['SINCE']  || raise(ArgumentError, 'SINCE required'))
    before    = Date.parse(ENV['BEFORE'] || raise(ArgumentError, 'BEFORE required'))
    completed = (ENV['COMPLETED'] || '').split(',').reject(&:empty?)
    failed    = (ENV['FAILED']    || '').split(',').reject(&:empty?)

    CloudKnowledgeDb::Config.ensure_write_host!

    result = CloudKnowledgeDb::Pipeline.finish(
      cfg: cfg, bookmark_path: LAST_RUN_PATH,
      completed: completed, failed: failed,
      since: since, before: before
    )

    record_run(result[:status], reason: result[:reason])

    if (copy_to = cfg['db_copy_to'])
      src = File.expand_path(cfg['db_path'], __dir__)
      dst = File.expand_path(copy_to)
      CloudKnowledgeDb::DbSyncer.sync(source: src, destination: dst)
      puts "[sync] db copied to #{dst}"
    end

    CloudKnowledgeDb::Notifier.notify(
      status: result[:status], since: since, before: before
    )
    puts "[pipeline:finish] status=#{result[:status]}"
  end
end
```

- [ ] **Step 2: Run full test suite**

```bash
APP_ENV=test bundle exec rake test
```

Expected: all tests pass

- [ ] **Step 3: Verify the three tasks appear in rake -T**

```bash
APP_ENV=test bundle exec rake -T pipeline
```

Expected output contains:
```
rake pipeline:finish  # Post-flight: mark_completed, record_run, db sync, notify
rake pipeline:source  # Run fetch→import→esa for one source (no bookmark writes)
rake pipeline:start   # Pre-flight: host/ollama check, esa preflight, mark_started all sources
```

- [ ] **Step 4: Commit**

```bash
git add Rakefile
git commit -m "feat(rake): add pipeline:start, pipeline:source, pipeline:finish tasks"
```

---

### Task 4: Refactor rake daily to sequential (remove threads and Mutex)

**Files:**
- Modify: `Rakefile`

The `task :daily` block uses `Mutex.new` and `Thread.new`. Replace with a sequential `each` loop. The logic per source is identical; only the threading wrapper is removed.

- [ ] **Step 1: Locate the threading block**

In Rakefile, find the `begin` block inside `task :daily` (around line 502). It looks like:

```ruby
  begin
    bookmark_mutex = Mutex.new
    t_total = Time.now

    threads = cfg['sources'].keys.map do |key|
      Thread.new do
        Thread.current.report_on_exception = true
        t_src_start = Time.now
        puts "==== #{key} (#{since}..#{before}) ===="

        bookmark_mutex.synchronize do
          d = TB.load(LAST_RUN_PATH)
          d = TB.mark_started(d, key, before: before, at: Time.now)
          TB.save(LAST_RUN_PATH, d)
        end

        begin
          t0 = Time.now
          dir = do_fetch(key, since: since.to_time, before: before.to_time)
          puts "[timing] #{key} fetch   #{(Time.now - t0).round(2)}s"

          t0 = Time.now
          do_import(key, dir: dir)
          puts "[timing] #{key} import  #{(Time.now - t0).round(2)}s"

          t0 = Time.now
          do_esa(key, dir: dir)
          puts "[timing] #{key} esa     #{(Time.now - t0).round(2)}s"

          puts "[timing] #{key} TOTAL   #{(Time.now - t_src_start).round(2)}s"

          bookmark_mutex.synchronize do
            d = TB.load(LAST_RUN_PATH)
            d = TB.mark_completed(d, key, before: before, at: Time.now,
              models_used: { 'daily_summarizer' => cfg['models']['daily_summarizer'] })
            TB.save(LAST_RUN_PATH, d)
          end
        rescue => e
          warn "SKIP #{key}: #{e.class}: #{e.message}"
          warn e.backtrace.first(5).join("\n") if ENV['DEBUG']
        end
      end
    end

    threads.each(&:join)
    puts "[timing] daily WALLCLOCK #{(Time.now - t_total).round(2)}s"
```

- [ ] **Step 2: Replace with sequential loop**

Replace the entire block above with:

```ruby
  begin
    t_total = Time.now

    cfg['sources'].keys.each do |key|
      t_src_start = Time.now
      puts "==== #{key} (#{since}..#{before}) ===="

      d = TB.load(LAST_RUN_PATH)
      d = TB.mark_started(d, key, before: before, at: Time.now)
      TB.save(LAST_RUN_PATH, d)

      begin
        t0  = Time.now
        dir = do_fetch(key, since: since.to_time, before: before.to_time)
        puts "[timing] #{key} fetch   #{(Time.now - t0).round(2)}s"

        t0 = Time.now
        do_import(key, dir: dir)
        puts "[timing] #{key} import  #{(Time.now - t0).round(2)}s"

        t0 = Time.now
        do_esa(key, dir: dir)
        puts "[timing] #{key} esa     #{(Time.now - t0).round(2)}s"

        puts "[timing] #{key} TOTAL   #{(Time.now - t_src_start).round(2)}s"

        d = TB.load(LAST_RUN_PATH)
        d = TB.mark_completed(d, key, before: before, at: Time.now,
              models_used: { 'daily_summarizer' => cfg['models']['daily_summarizer'] })
        TB.save(LAST_RUN_PATH, d)
      rescue => e
        warn "SKIP #{key}: #{e.class}: #{e.message}"
        warn e.backtrace.first(5).join("\n") if ENV['DEBUG']
      end
    end

    puts "[timing] daily WALLCLOCK #{(Time.now - t_total).round(2)}s"
```

- [ ] **Step 3: Run full test suite**

```bash
APP_ENV=test bundle exec rake test
```

Expected: all tests pass

- [ ] **Step 4: Commit**

```bash
git add Rakefile
git commit -m "refactor(rake): make rake daily sequential, remove Ruby threads and Mutex"
```

---

### Task 5: Update cloud-knowledge-db-run agent for pipeline tasks

**Files:**
- Modify: `.claude/agents/cloud-knowledge-db-run.md`

- [ ] **Step 1: Add pipeline tasks to the task routing table**

Find the markdown table under "Task routing". It currently has rows for `daily`, `fetch:<key>`, `import:<key>`, `esa:<key>`, `db:delete_polluted`, `esa:delete`. Add three new rows:

```markdown
| `pipeline:start`     | `rake pipeline:start`                   | `SINCE=YYYY-MM-DD BEFORE=YYYY-MM-DD`                               |
| `pipeline:source`    | `rake pipeline:source SOURCE=<key>`     | `SOURCE=<key> SINCE=YYYY-MM-DD BEFORE=YYYY-MM-DD`                  |
| `pipeline:finish`    | `rake pipeline:finish`                  | `COMPLETED=<csv> FAILED=<csv> SINCE=YYYY-MM-DD BEFORE=YYYY-MM-DD`  |
```

- [ ] **Step 2: Extend AUTOCONFIRM to cover pipeline tasks**

Find the rule:

```markdown
1. **AUTOCONFIRM mode** — the prompt contains the literal token `AUTOCONFIRM` (case-sensitive) AND `TASK=daily`.
```

Replace with:

```markdown
1. **AUTOCONFIRM mode** — the prompt contains the literal token `AUTOCONFIRM` (case-sensitive) AND `TASK=` is one of: `daily`, `pipeline:start`, `pipeline:source`, `pipeline:finish`. These are the only tasks that the workflow and router dispatch without the PLAN/CONFIRMED two-stage gate. **`AUTOCONFIRM` is rejected for destructive tasks** (`db:delete_polluted`, `esa:delete`) — those always require PLAN/CONFIRMED.
```

- [ ] **Step 3: Run full test suite**

```bash
APP_ENV=test bundle exec rake test
```

Expected: all tests pass

- [ ] **Step 4: Commit**

```bash
git add .claude/agents/cloud-knowledge-db-run.md
git commit -m "feat(agents): add pipeline:start/source/finish routing and AUTOCONFIRM extension"
```

---

### Task 6: Generate and save the daily-pipeline workflow script

**Files:**
- Create: `.claude/workflows/daily-pipeline.js`

The Claude workflow runtime executes a JavaScript orchestration script. Claude generates it from a task description.

- [ ] **Step 1: Generate the workflow script**

In the Claude Code session (not a subagent), type the following prompt with the `ultracode` keyword so Claude writes and saves the workflow:

```
ultracode: write and save a workflow script to .claude/workflows/daily-pipeline.js

The workflow orchestrates the cloud-knowledge-db daily pipeline in 4 stages:

Stage 1 — spawn cloud-knowledge-db-inspect agent (model: haiku) with prompt:
  INTENT=last_run
  Parse the YAML output to find recommended_since_floor (the minimum last_completed_before across all sources). Use that as SINCE. Set BEFORE to today's date in YYYY-MM-DD format.

Stage 2 — spawn cloud-knowledge-db-run agent (model: sonnet) with prompt:
  AUTOCONFIRM TASK=pipeline:start SINCE={since} BEFORE={before} APP_ENV=production
  If the output contains "aborted", stop the workflow and surface the conflict details to the caller.

Stage 3 — fan out 5 parallel cloud-knowledge-db-run agents (model: sonnet each), one per source key.
  Source keys: aws_blog, gcp_blog, gws_blog, gitlab_blog, classmethod_blog
  Each agent prompt: AUTOCONFIRM TASK=pipeline:source SOURCE={key} SINCE={since} BEFORE={before} APP_ENV=production
  Capture per-source success or failure. A source fails if its agent exits with an error.

Stage 4 — spawn cloud-knowledge-db-run agent (model: sonnet) with prompt:
  AUTOCONFIRM TASK=pipeline:finish COMPLETED={comma-joined successful source keys} FAILED={comma-joined failed source keys} SINCE={since} BEFORE={before} APP_ENV=production

Return a final summary listing which sources completed and which failed.
```

- [ ] **Step 2: Verify the script was created**

```bash
ls -la /Users/bash/dev/src/github.com/bash0C7/cloud-knowledge-db/.claude/workflows/
```

Expected: `daily-pipeline.js` present

- [ ] **Step 3: Review the generated script for correctness**

Read `.claude/workflows/daily-pipeline.js` and verify:
- Stage 1 parses `recommended_since_floor` from TrunkBookmark YAML output
- Stage 3 dispatches 5 agents concurrently (not sequentially)
- Stage 2 handles the `aborted` case and stops the workflow
- Stage 4 receives the correct COMPLETED/FAILED CSV lists

Fix any issues by editing the script directly.

- [ ] **Step 4: Run full test suite**

```bash
APP_ENV=test bundle exec rake test
```

Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add .claude/workflows/daily-pipeline.js
git commit -m "feat(workflow): add daily-pipeline workflow script (parallel per-source)"
```

---

### Task 7: Update router skill daily fast path

**Files:**
- Modify: `.claude/commands/cloud-knowledge-db.md`

- [ ] **Step 1: Replace the daily fast path dispatch section**

Find the section "#### For the daily fast path" and the dispatch table row for daily. Replace both.

The dispatch section currently says:
```markdown
#### For the daily fast path

Single invocation, no PLAN cycle. Prompt template:

```
AUTOCONFIRM TASK=daily APP_ENV=production
[free-form context from the user, if any]
```

The subagent runs `bundle exec rake daily` directly. Whatever it returns (success summary, abort with esa conflicts, or failure with reason), relay verbatim to the user. If the result is `aborted`, follow up by offering options: inspect the conflicting esa post via `cloud-knowledge-db-inspect`, delete it via the `掃除` choice, or re-kick with `CKDB_FORCE=1` (which the user must confirm explicitly — do not auto-set it).
```

Replace with:

```markdown
#### For the daily fast path

Trigger the `/daily-pipeline` saved workflow instead of dispatching a single run agent. The workflow handles bookmark reading, preflight, 5-way parallel source execution, and finish internally — intermediate results stay in workflow script variables, not in this session's context.

Say: "Run /daily-pipeline" — the runtime picks up `.claude/workflows/daily-pipeline.js`.

When the workflow completes, relay its summary to the user.

**If the workflow reports `aborted`** (esa conflicts): offer to inspect the conflicting post via `cloud-knowledge-db-inspect`, delete it via the `掃除` path, or re-kick the workflow with `CKDB_FORCE=1` (user must confirm explicitly — do not auto-set it).

**If one or more sources failed**: the workflow surfaces which sources failed. Offer targeted retry: dispatch `cloud-knowledge-db-run` with `AUTOCONFIRM TASK=pipeline:source SOURCE=<failed_key> SINCE=<same-since> BEFORE=<same-before> APP_ENV=production`.
```

- [ ] **Step 2: Update the dispatch table row**

Find the table row:

```markdown
| **daily fast path** | `cloud-knowledge-db-run` subagent with `AUTOCONFIRM TASK=daily APP_ENV=production` (single invocation, no PLAN/CONFIRMED) |
```

Replace with:

```markdown
| **daily fast path** | Run `/daily-pipeline` workflow (saves intermediate results in script variables; 5 parallel source agents) |
```

- [ ] **Step 3: Run full test suite**

```bash
APP_ENV=test bundle exec rake test
```

Expected: all tests pass

- [ ] **Step 4: Commit**

```bash
git add .claude/commands/cloud-knowledge-db.md
git commit -m "feat(router): daily fast path triggers /daily-pipeline workflow"
```

---

### Task 8: Add pipeline task coverage to contamination test

**Files:**
- Modify: `test/test_contamination.rb`

The existing `ContaminationTest` checks `DailySummarizer::SYSTEM_PROMPT` and `ContentClassifier::SYSTEM_PROMPT` for gyaru/persona markers. The `pipeline:source` task calls `do_esa` which uses `DailySummarizer` — so the existing `DailySummarizer` test already covers it. Add an explicit test that confirms `pipeline:source` routes through `DailySummarizer` (not a new or unwrapped LLM call).

- [ ] **Step 1: Add the pipeline source test**

Add the following test method to the `ContaminationTest` class in `test/test_contamination.rb`:

```ruby
  def test_pipeline_source_esa_uses_daily_summarizer
    # pipeline:source calls do_esa which instantiates DailySummarizer.
    # Verify DailySummarizer::SYSTEM_PROMPT is still present and clean
    # (guards against future refactor that might inline a bare LLM call).
    assert defined?(CloudKnowledgeDb::DailySummarizer::SYSTEM_PROMPT),
           'DailySummarizer::SYSTEM_PROMPT must exist for pipeline:source esa phase'
    prompt = CloudKnowledgeDb::DailySummarizer::SYSTEM_PROMPT
    CONTAMINATION_MARKERS.each do |m|
      assert_false prompt.include?(m),
                   "pipeline:source esa path: DailySummarizer SYSTEM_PROMPT contains #{m}"
    end
  end
```

- [ ] **Step 2: Run full test suite**

```bash
APP_ENV=test bundle exec rake test
```

Expected: all tests pass (new test green from the start — it validates an invariant that already holds)

- [ ] **Step 3: Commit**

```bash
git add test/test_contamination.rb
git commit -m "test(contamination): add pipeline:source esa path coverage"
```
