# Daily 自動化 (人間介在ゼロ完走) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `rake daily` を skill 経由で kick した後、ターン往復ゼロで完走させる。esa 二重投稿の事前回避と yml への状況記録 (ok / aborted / failed) と OS 通知を備える。

**Architecture:** Ruby 側に `EsaToken` (keychain token 共有) / `EsaPreflight` (live esa API で base_name 衝突検出) / `Notifier` (osascript ラッパー) の 3 module を新設。`Rakefile` に `:plan` task と、`:daily` の冒頭 preflight gate / 終端 record_run + 通知を組む。`.claude/commands/cloud-knowledge-db.md` の daily intent と `.claude/agents/cloud-knowledge-db-run.md` に AUTOCONFIRM fast path を追加して PLAN/CONFIRMED gate をスキップする。

**Tech Stack:** Ruby 4.0, test-unit, sqlite3 + sqlite_vec (既存), net/http, esa.io API, ollama HTTP, macOS osascript (`/usr/bin/osascript`), `/usr/bin/security` (keychain).

**Spec:** `docs/superpowers/specs/2026-04-30-daily-automation-design.md`

---

## File Structure

新規:
- `lib/cloud_knowledge_db/esa_token.rb` — keychain から esa-mcp-token を取得する module
- `lib/cloud_knowledge_db/esa_preflight.rb` — `Conflict` struct + `EsaPreflight.conflicts` + `DefaultSearcher` / `StubSearcher`
- `lib/cloud_knowledge_db/notifier.rb` — osascript で OS 通知 (ok / aborted / failed)
- `test/test_esa_token.rb`
- `test/test_esa_preflight.rb`
- `test/test_notifier.rb`
- `test/test_daily_pipeline.rb` — `record_run` helper の単体検証

改造:
- `lib/cloud_knowledge_db/esa_writer.rb` — `fetch_token` を `EsaToken.fetch` 委譲に変更
- `Rakefile` — `:plan` 新設、`:daily` に preflight + record_run + Notifier、helper `record_run` 追加
- `.claude/commands/cloud-knowledge-db.md` — daily fast path 追加
- `.claude/agents/cloud-knowledge-db-run.md` — `AUTOCONFIRM TASK=daily` token 追加
- `CLAUDE.md` — 新規 lib 責務、`last_run` セクション、`CKDB_FORCE` の記述追加

---

## Task 1: `EsaToken` module を切り出す

esa keychain token 取得を独立 module に分離する。`EsaWriter` が今 private method として持っている処理を共通化し、`EsaPreflight::DefaultSearcher` でも使えるようにする。

**Files:**
- Create: `lib/cloud_knowledge_db/esa_token.rb`
- Create: `test/test_esa_token.rb`
- Modify: `lib/cloud_knowledge_db/esa_writer.rb`

- [ ] **Step 1.1: Write failing test for `EsaToken.fetch`**

Create `test/test_esa_token.rb`:

```ruby
# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/esa_token'

class EsaTokenTest < Test::Unit::TestCase
  def test_fetch_returns_stripped_token
    runner = -> { "abc123\n" }
    assert_equal 'abc123', CloudKnowledgeDb::EsaToken.fetch(runner: runner)
  end

  def test_fetch_raises_when_token_empty
    runner = -> { "" }
    assert_raise(RuntimeError) do
      CloudKnowledgeDb::EsaToken.fetch(runner: runner)
    end
  end

  def test_fetch_raises_when_token_whitespace_only
    runner = -> { "   \n" }
    assert_raise(RuntimeError) do
      CloudKnowledgeDb::EsaToken.fetch(runner: runner)
    end
  end
end
```

- [ ] **Step 1.2: Run test to confirm it fails**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/cloud-knowledge-db && \
  bundle exec ruby -Itest test/test_esa_token.rb
```

Expected: `LoadError: cannot load such file -- cloud_knowledge_db/esa_token`

- [ ] **Step 1.3: Commit RED**

```bash
git add test/test_esa_token.rb
git -c commit.gpgsign=false commit -m "test: add failing spec for EsaToken.fetch"
```

- [ ] **Step 1.4: Implement minimal `EsaToken`**

Create `lib/cloud_knowledge_db/esa_token.rb`:

```ruby
# frozen_string_literal: true

module CloudKnowledgeDb
  module EsaToken
    KEY = 'esa-mcp-token'

    def self.fetch(runner: nil)
      r = runner || method(:default_fetch)
      token = r.call.to_s.strip
      raise "ESA token not found in keychain (key: #{KEY})" if token.empty?
      token
    end

    def self.default_fetch
      `/usr/bin/security find-generic-password -s '#{KEY}' -w 2>/dev/null`
    end
  end
end
```

- [ ] **Step 1.5: Run test to confirm it passes**

```bash
bundle exec ruby -Itest test/test_esa_token.rb
```

Expected: 3 tests pass.

- [ ] **Step 1.6: Commit GREEN**

```bash
git add lib/cloud_knowledge_db/esa_token.rb
git -c commit.gpgsign=false commit -m "feat: add EsaToken module for shared keychain access"
```

- [ ] **Step 1.7: Refactor `EsaWriter#fetch_token` to delegate to `EsaToken.fetch`**

Modify `lib/cloud_knowledge_db/esa_writer.rb`:

Change:
```ruby
require 'net/http'
require 'uri'
require 'json'

module CloudKnowledgeDb
  class EsaWriter
```

to:
```ruby
require 'net/http'
require 'uri'
require 'json'
require_relative 'esa_token'

module CloudKnowledgeDb
  class EsaWriter
```

And replace the private `fetch_token` block:
```ruby
    private

    def fetch_token
      token = `/usr/bin/security find-generic-password -s 'esa-mcp-token' -w 2>/dev/null`.strip
      abort "ESA token not found in keychain (key: esa-mcp-token)" if token.empty?
      token
    end
```

with:
```ruby
    private

    def fetch_token
      EsaToken.fetch
    end
```

- [ ] **Step 1.8: Run full test suite to verify no regression**

```bash
bundle exec rake test
```

Expected: all existing tests + new EsaToken tests pass.

- [ ] **Step 1.9: Commit REFACTOR**

```bash
git add lib/cloud_knowledge_db/esa_writer.rb
git -c commit.gpgsign=false commit -m "refactor: delegate EsaWriter#fetch_token to EsaToken.fetch"
```

---

## Task 2: `EsaPreflight` skeleton (Conflict struct + StubSearcher + empty case)

最小骨格: `Conflict` struct と `StubSearcher`、`EsaPreflight.conflicts` が空配列を返すケース。

**Files:**
- Create: `lib/cloud_knowledge_db/esa_preflight.rb`
- Create: `test/test_esa_preflight.rb`

- [ ] **Step 2.1: Write failing test for empty conflicts**

Create `test/test_esa_preflight.rb`:

```ruby
# frozen_string_literal: true
require_relative 'test_helper'
require 'date'
require 'cloud_knowledge_db/esa_preflight'

class EsaPreflightTest < Test::Unit::TestCase
  def base_cfg
    {
      'esa' => {
        'team' => 'bist',
        'sources' => {
          'aws_blog' => { 'category' => 'test/cloud-trunk-changes/aws' }
        }
      },
      'sources' => {
        'aws_blog' => { 'short_name' => 'aws' }
      }
    }
  end

  def test_no_conflicts_returns_empty_array
    searcher = CloudKnowledgeDb::EsaPreflight::StubSearcher.new
    result = CloudKnowledgeDb::EsaPreflight.conflicts(
      cfg: base_cfg,
      since: Date.new(2026, 4, 29),
      before: Date.new(2026, 4, 30),
      searcher: searcher
    )
    assert_equal [], result
  end
end
```

- [ ] **Step 2.2: Run test to confirm it fails**

```bash
bundle exec ruby -Itest test/test_esa_preflight.rb
```

Expected: `LoadError: cannot load such file -- cloud_knowledge_db/esa_preflight`

- [ ] **Step 2.3: Commit RED**

```bash
git add test/test_esa_preflight.rb
git -c commit.gpgsign=false commit -m "test: add failing spec for EsaPreflight skeleton"
```

- [ ] **Step 2.4: Implement skeleton**

Create `lib/cloud_knowledge_db/esa_preflight.rb`:

```ruby
# frozen_string_literal: true
require_relative 'esa_naming'

module CloudKnowledgeDb
  module EsaPreflight
    Conflict = Struct.new(
      :source, :date, :name, :category,
      :existing_post_number, :existing_post_url,
      keyword_init: true
    )

    def self.conflicts(cfg:, since:, before:, searcher:)
      results = []
      team = cfg.dig('esa', 'team')
      cfg.dig('esa', 'sources').each do |source_key, esa_src|
        short = cfg.dig('sources', source_key, 'short_name')
        (since...before).each do |date|
          date_str = date.to_s
          name     = EsaNaming.build_name(date: date_str, short_name: short)
          category = EsaNaming.build_category(prefix: esa_src['category'], date: date_str)
          posts    = searcher.search(team: team, category: category, name: name) || []
          posts.each do |p|
            results << Conflict.new(
              source: source_key, date: date_str,
              name: name, category: category,
              existing_post_number: p['number'],
              existing_post_url:    p['url']
            )
          end
        end
      end
      results
    end

    class StubSearcher
      def initialize(posts_by_query = {})
        @posts_by_query = posts_by_query
      end

      def search(team:, category:, name:)
        @posts_by_query[[team, category, name]] || []
      end
    end
  end
end
```

- [ ] **Step 2.5: Run test to confirm it passes**

```bash
bundle exec ruby -Itest test/test_esa_preflight.rb
```

Expected: 1 test passes.

- [ ] **Step 2.6: Commit GREEN**

```bash
git add lib/cloud_knowledge_db/esa_preflight.rb
git -c commit.gpgsign=false commit -m "feat: add EsaPreflight skeleton with Conflict struct and StubSearcher"
```

---

## Task 3: `EsaPreflight.conflicts` core iteration

衝突 1 件 / 複数日 / 複数 source / classmethod 除外を仕様化する。

**Files:**
- Modify: `test/test_esa_preflight.rb`

- [ ] **Step 3.1: Add failing test — single conflict for one source/day**

Append to `test/test_esa_preflight.rb` inside `EsaPreflightTest`:

```ruby
  def test_one_conflict_when_existing_post_returned
    searcher = CloudKnowledgeDb::EsaPreflight::StubSearcher.new(
      [['bist', 'test/cloud-trunk-changes/aws/2026/04/29', '2026-04-29-aws-cloud-changes']] => [
        { 'number' => 137, 'url' => 'https://bist.esa.io/posts/137' }
      ]
    )
    result = CloudKnowledgeDb::EsaPreflight.conflicts(
      cfg: base_cfg,
      since: Date.new(2026, 4, 29),
      before: Date.new(2026, 4, 30),
      searcher: searcher
    )
    assert_equal 1, result.size
    c = result.first
    assert_equal 'aws_blog', c.source
    assert_equal '2026-04-29', c.date
    assert_equal '2026-04-29-aws-cloud-changes', c.name
    assert_equal 'test/cloud-trunk-changes/aws/2026/04/29', c.category
    assert_equal 137, c.existing_post_number
    assert_equal 'https://bist.esa.io/posts/137', c.existing_post_url
  end
```

- [ ] **Step 3.2: Run test to verify it passes (existing implementation already covers this)**

```bash
bundle exec ruby -Itest test/test_esa_preflight.rb -n test_one_conflict_when_existing_post_returned
```

Expected: PASS (the skeleton already iterates correctly).

- [ ] **Step 3.3: Add failing test — multi-day window expansion**

Append:

```ruby
  def test_multi_day_window_expands_per_day
    searcher = CloudKnowledgeDb::EsaPreflight::StubSearcher.new(
      [['bist', 'test/cloud-trunk-changes/aws/2026/04/26', '2026-04-26-aws-cloud-changes']] => [
        { 'number' => 100, 'url' => 'https://bist.esa.io/posts/100' }
      ],
      [['bist', 'test/cloud-trunk-changes/aws/2026/04/29', '2026-04-29-aws-cloud-changes']] => [
        { 'number' => 137, 'url' => 'https://bist.esa.io/posts/137' }
      ]
    )
    result = CloudKnowledgeDb::EsaPreflight.conflicts(
      cfg: base_cfg,
      since: Date.new(2026, 4, 25),
      before: Date.new(2026, 4, 30),
      searcher: searcher
    )
    assert_equal 2, result.size
    assert_equal %w[2026-04-26 2026-04-29], result.map(&:date).sort
  end
```

- [ ] **Step 3.4: Run test to verify**

```bash
bundle exec ruby -Itest test/test_esa_preflight.rb -n test_multi_day_window_expands_per_day
```

Expected: PASS.

- [ ] **Step 3.5: Add failing test — multiple official sources covered**

Append:

```ruby
  def multi_source_cfg
    {
      'esa' => {
        'team' => 'bist',
        'sources' => {
          'aws_blog'    => { 'category' => 'test/c/aws' },
          'gitlab_blog' => { 'category' => 'test/c/gitlab' }
        }
      },
      'sources' => {
        'aws_blog'    => { 'short_name' => 'aws' },
        'gitlab_blog' => { 'short_name' => 'gitlab' },
        # classmethod_blog has no esa.sources entry, so it must be skipped
        'classmethod_blog' => { 'short_name' => 'classmethod' }
      }
    }
  end

  def test_classmethod_excluded_from_check
    searcher = CloudKnowledgeDb::EsaPreflight::StubSearcher.new(
      [['bist', 'test/c/aws/2026/04/29', '2026-04-29-aws-cloud-changes']]    => [{ 'number' => 1, 'url' => 'u1' }],
      [['bist', 'test/c/gitlab/2026/04/29', '2026-04-29-gitlab-cloud-changes']] => [{ 'number' => 2, 'url' => 'u2' }]
    )
    result = CloudKnowledgeDb::EsaPreflight.conflicts(
      cfg: multi_source_cfg,
      since: Date.new(2026, 4, 29),
      before: Date.new(2026, 4, 30),
      searcher: searcher
    )
    sources = result.map(&:source).sort
    assert_equal %w[aws_blog gitlab_blog], sources
    refute_includes sources, 'classmethod_blog'
  end
```

- [ ] **Step 3.6: Run test to verify**

```bash
bundle exec ruby -Itest test/test_esa_preflight.rb -n test_classmethod_excluded_from_check
```

Expected: PASS (classmethod has no `esa.sources` entry → automatically skipped).

- [ ] **Step 3.7: Run all EsaPreflight tests**

```bash
bundle exec ruby -Itest test/test_esa_preflight.rb
```

Expected: 4 tests pass.

- [ ] **Step 3.8: Commit additional test cases**

```bash
git add test/test_esa_preflight.rb
git -c commit.gpgsign=false commit -m "test: add EsaPreflight cases for conflict, multi-day, classmethod exclusion"
```

---

## Task 4: `EsaPreflight::DefaultSearcher` (live esa API)

HTTP 実装を追加する。HTTP の実 mock は overengineering なので test は (a) `EsaToken.fetch` を呼ぶ interface と (b) URI 構築だけに絞る。実 API call は手動 smoke test に任せる。

**Files:**
- Modify: `lib/cloud_knowledge_db/esa_preflight.rb`
- Modify: `test/test_esa_preflight.rb`

- [ ] **Step 4.1: Write failing test — DefaultSearcher constructs query URL correctly**

Append to `test/test_esa_preflight.rb`:

```ruby
  def test_default_searcher_builds_query_url
    captured = nil
    fake_http = ->(uri, _req) { captured = uri.to_s; OpenStruct.new(code: '200', body: '{"posts":[]}') }
    searcher = CloudKnowledgeDb::EsaPreflight::DefaultSearcher.new(
      cfg: { 'esa' => { 'team' => 'bist' } },
      token: 'tok',
      http_runner: fake_http
    )
    searcher.search(team: 'bist', category: 'test/c/aws/2026/04/29', name: '2026-04-29-aws-cloud-changes')
    assert_match %r{api\.esa\.io/v1/teams/bist/posts}, captured
    assert_match %r{q=}, captured
    assert_match %r{category%3A}, captured
    assert_match %r{name%3A}, captured
  end

  def test_default_searcher_returns_posts_array_on_2xx
    fake_http = ->(_uri, _req) { OpenStruct.new(code: '200', body: '{"posts":[{"number":7,"url":"u"}]}') }
    searcher = CloudKnowledgeDb::EsaPreflight::DefaultSearcher.new(
      cfg: { 'esa' => { 'team' => 'bist' } },
      token: 'tok',
      http_runner: fake_http
    )
    posts = searcher.search(team: 'bist', category: 'c', name: 'n')
    assert_equal [{ 'number' => 7, 'url' => 'u' }], posts
  end

  def test_default_searcher_raises_on_4xx
    fake_http = ->(_uri, _req) { OpenStruct.new(code: '403', body: 'forbidden') }
    searcher = CloudKnowledgeDb::EsaPreflight::DefaultSearcher.new(
      cfg: { 'esa' => { 'team' => 'bist' } },
      token: 'tok',
      http_runner: fake_http
    )
    assert_raise(RuntimeError) do
      searcher.search(team: 'bist', category: 'c', name: 'n')
    end
  end
```

Add `require 'ostruct'` at the top of `test/test_esa_preflight.rb` if it's not already there.

- [ ] **Step 4.2: Run tests to confirm they fail**

```bash
bundle exec ruby -Itest test/test_esa_preflight.rb
```

Expected: 3 new tests fail with `NameError: uninitialized constant ...DefaultSearcher`.

- [ ] **Step 4.3: Commit RED**

```bash
git add test/test_esa_preflight.rb
git -c commit.gpgsign=false commit -m "test: add failing specs for EsaPreflight::DefaultSearcher"
```

- [ ] **Step 4.4: Implement DefaultSearcher**

Append to `lib/cloud_knowledge_db/esa_preflight.rb`, before the closing `end` of `module EsaPreflight`:

```ruby
    class DefaultSearcher
      def initialize(cfg:, token: nil, http_runner: nil)
        @cfg         = cfg
        @token       = token || EsaToken.fetch
        @http_runner = http_runner || method(:default_http_call)
      end

      def search(team:, category:, name:)
        q = URI.encode_www_form_component("category:#{category} name:#{name}")
        uri = URI("https://api.esa.io/v1/teams/#{team}/posts?q=#{q}&per_page=100")
        req = Net::HTTP::Get.new(uri.request_uri)
        req['Authorization'] = "Bearer #{@token}"
        res = @http_runner.call(uri, req)
        raise "esa API error (#{res.code}): #{res.body}" if res.code.to_i >= 400
        JSON.parse(res.body)['posts'] || []
      end

      private

      def default_http_call(uri, req)
        Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
      end
    end
```

Add the necessary `require`s at the top of the file:

```ruby
# frozen_string_literal: true
require 'net/http'
require 'uri'
require 'json'
require_relative 'esa_naming'
require_relative 'esa_token'
```

- [ ] **Step 4.5: Run all EsaPreflight tests**

```bash
bundle exec ruby -Itest test/test_esa_preflight.rb
```

Expected: 7 tests pass.

- [ ] **Step 4.6: Commit GREEN**

```bash
git add lib/cloud_knowledge_db/esa_preflight.rb
git -c commit.gpgsign=false commit -m "feat: implement EsaPreflight::DefaultSearcher with HTTP DI"
```

---

## Task 5: `Notifier` module

osascript で OS 通知を出す。`runner:` kwarg で system 呼び出しを stub できるようにする。

**Files:**
- Create: `lib/cloud_knowledge_db/notifier.rb`
- Create: `test/test_notifier.rb`

- [ ] **Step 5.1: Write failing test for Notifier**

Create `test/test_notifier.rb`:

```ruby
# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/notifier'

class NotifierTest < Test::Unit::TestCase
  def setup
    @recorded = []
    @runner = ->(*args) { @recorded << args; true }
  end

  def test_notify_ok_uses_ok_title
    CloudKnowledgeDb::Notifier.notify(status: 'ok', since: '2026-04-29', before: '2026-04-30', runner: @runner)
    assert_equal 1, @recorded.size
    cmd = @recorded.first
    assert_equal 'osascript', cmd[0]
    assert_equal '-e', cmd[1]
    assert_match(/✓ daily ok/, cmd[2])
    assert_match(/2026-04-29/, cmd[2])
    assert_match(/2026-04-30/, cmd[2])
  end

  def test_notify_aborted_uses_reason_as_body
    CloudKnowledgeDb::Notifier.notify(status: 'aborted', reason: 'esa conflict: 2件', runner: @runner)
    cmd = @recorded.first
    assert_match(/⚠ daily aborted/, cmd[2])
    assert_match(/esa conflict: 2件/, cmd[2])
  end

  def test_notify_failed_uses_failed_title
    CloudKnowledgeDb::Notifier.notify(status: 'failed', reason: 'StandardError', runner: @runner)
    cmd = @recorded.first
    assert_match(/✗ daily failed/, cmd[2])
    assert_match(/StandardError/, cmd[2])
  end

  def test_notify_unknown_status_does_not_raise
    CloudKnowledgeDb::Notifier.notify(status: 'bogus', runner: @runner)
    assert_equal [], @recorded
  end

  def test_notify_runner_failure_is_swallowed
    raising_runner = ->(*_args) { raise 'osascript missing' }
    CloudKnowledgeDb::Notifier.notify(status: 'ok', runner: raising_runner)
    # if this returned, the rescue worked
    assert_true true
  end
end
```

- [ ] **Step 5.2: Run test to verify it fails**

```bash
bundle exec ruby -Itest test/test_notifier.rb
```

Expected: `LoadError: cannot load such file -- cloud_knowledge_db/notifier`

- [ ] **Step 5.3: Commit RED**

```bash
git add test/test_notifier.rb
git -c commit.gpgsign=false commit -m "test: add failing spec for Notifier"
```

- [ ] **Step 5.4: Implement Notifier**

Create `lib/cloud_knowledge_db/notifier.rb`:

```ruby
# frozen_string_literal: true

module CloudKnowledgeDb
  module Notifier
    TITLES = {
      'ok'      => '✓ daily ok',
      'aborted' => '⚠ daily aborted',
      'failed'  => '✗ daily failed'
    }.freeze

    def self.notify(status:, since: nil, before: nil, reason: nil, runner: nil)
      title = TITLES[status]
      return unless title
      body = reason || "[#{since}, #{before})"
      r = runner || method(:default_run)
      r.call('osascript', '-e', %Q(display notification "#{body}" with title "#{title}"))
    rescue => e
      warn "[notifier] failed: #{e.message}"
    end

    def self.default_run(*args)
      system(*args)
    end
  end
end
```

- [ ] **Step 5.5: Run test to verify it passes**

```bash
bundle exec ruby -Itest test/test_notifier.rb
```

Expected: 5 tests pass.

- [ ] **Step 5.6: Commit GREEN**

```bash
git add lib/cloud_knowledge_db/notifier.rb
git -c commit.gpgsign=false commit -m "feat: add Notifier module with 3-status osascript wrapper"
```

---

## Task 6: Rakefile `:plan` task

read-only な preflight 出力 task。esa API は live 呼び出しなので token と DB の準備された production-like 環境でだけ完全動作する。dev / test 環境では HTTP error で raise してもよい (preflight は run-only)。

**Files:**
- Modify: `Rakefile`

- [ ] **Step 6.1: Add `:plan` task to Rakefile**

Modify `Rakefile`. After the `require_relative 'lib/cloud_knowledge_db/db_syncer'` line, add:

```ruby
require_relative 'lib/cloud_knowledge_db/esa_preflight'
require_relative 'lib/cloud_knowledge_db/notifier'
```

After the `task default: :test` line, after the `LAST_RUN_PATH` and `TB` constants, add a new helper for window resolution and the `:plan` task:

```ruby
def resolve_daily_window
  require 'date'
  before = ENV['BEFORE'] ? Date.parse(ENV['BEFORE']) : Date.today
  data   = TB.load(LAST_RUN_PATH)
  since  = if ENV['SINCE']
             Date.parse(ENV['SINCE'])
           else
             floor = TB.recommended_since_floor(data, cfg['sources'].keys)
             floor ? Date.parse(floor) : (before - 1)
           end
  [since, before]
end

desc 'preflight: list esa base_name conflicts (read-only)'
task :plan do
  require 'json'
  since_d, before_d = resolve_daily_window
  searcher  = CloudKnowledgeDb::EsaPreflight::DefaultSearcher.new(cfg: cfg)
  conflicts = CloudKnowledgeDb::EsaPreflight.conflicts(
    cfg: cfg, since: since_d, before: before_d, searcher: searcher
  )
  puts JSON.pretty_generate(
    since: since_d.to_s,
    before: before_d.to_s,
    conflicts: conflicts.map(&:to_h)
  )
end
```

- [ ] **Step 6.2: Verify `rake -T` shows the new task**

```bash
APP_ENV=test bundle exec rake -T | grep plan
```

Expected: `rake plan      # preflight: list esa base_name conflicts (read-only)`

- [ ] **Step 6.3: Verify `rake plan` runs (test env, may hit esa API)**

This step requires a working esa keychain entry. If the keychain is set up:

```bash
APP_ENV=test bundle exec rake plan SINCE=2026-04-29 BEFORE=2026-04-30
```

Expected: JSON output with `since`, `before`, and `conflicts: []` (test env has no posts).

If the keychain is not set up or the network is unavailable, document the failure mode and continue — `:plan` will only be reliably runnable in the production-like environment.

- [ ] **Step 6.4: Commit**

```bash
git add Rakefile
git -c commit.gpgsign=false commit -m "feat: add rake plan task for preflight conflict listing"
```

---

## Task 7: `record_run` helper + Rakefile `:daily` integration

`record_run` を Rakefile top-level method として追加し、`:daily` の冒頭に preflight gate、終端に record_run + Notifier を組む。

**Files:**
- Create: `test/test_daily_pipeline.rb`
- Modify: `Rakefile`

- [ ] **Step 7.1: Write failing test for `record_run` behavior**

Create `test/test_daily_pipeline.rb`:

```ruby
# frozen_string_literal: true
require_relative 'test_helper'
require 'tmpdir'
require 'yaml'
require 'cloud_knowledge_db/trunk_bookmark'

class DailyPipelineTest < Test::Unit::TestCase
  # We test the pure-Ruby record_run logic in isolation by reproducing
  # the same algorithm. The actual Rakefile method is exercised in the
  # smoke test phase. This guards against accidental yml shape changes.

  def record_run_under_test(path, status, reason: nil, now: Time.now)
    data = CloudKnowledgeDb::TrunkBookmark.load(path)
    data['last_run'] = {
      'status'      => status,
      'finished_at' => now.iso8601,
      'reason'      => reason
    }
    CloudKnowledgeDb::TrunkBookmark.save(path, data)
  end

  def test_record_ok_writes_status_finished_at_and_nil_reason
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'last_run.yml')
      now  = Time.utc(2026, 4, 30, 0, 8, 30)
      record_run_under_test(path, 'ok', now: now)
      h = YAML.load_file(path)
      assert_equal 'ok', h['last_run']['status']
      assert_equal '2026-04-30T00:08:30Z', h['last_run']['finished_at']
      assert_nil h['last_run']['reason']
    end
  end

  def test_record_aborted_writes_reason
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'last_run.yml')
      record_run_under_test(path, 'aborted', reason: 'esa conflict: 2件')
      h = YAML.load_file(path)
      assert_equal 'aborted', h['last_run']['status']
      assert_equal 'esa conflict: 2件', h['last_run']['reason']
    end
  end

  def test_record_run_preserves_existing_per_source_blocks
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'last_run.yml')
      File.write(path, { 'aws_blog' => { 'last_completed_before' => '2026-04-29' } }.to_yaml)
      record_run_under_test(path, 'ok')
      h = YAML.load_file(path)
      assert_equal '2026-04-29', h['aws_blog']['last_completed_before']
      assert_equal 'ok', h['last_run']['status']
    end
  end
end
```

- [ ] **Step 7.2: Run test to confirm it passes**

(The test exercises the `TrunkBookmark.load`/`save` round trip with the algorithm we will copy into Rakefile. The test itself is self-contained.)

```bash
bundle exec ruby -Itest test/test_daily_pipeline.rb
```

Expected: 3 tests pass (this is intentionally a contract test — the real Rakefile method must follow the same shape).

- [ ] **Step 7.3: Commit contract test**

```bash
git add test/test_daily_pipeline.rb
git -c commit.gpgsign=false commit -m "test: add contract spec for last_run.yml record_run shape"
```

- [ ] **Step 7.4: Add `record_run` helper to Rakefile**

Modify `Rakefile`. Right after the `resolve_daily_window` definition added in Task 6, add:

```ruby
def record_run(status, reason: nil)
  data = TB.load(LAST_RUN_PATH)
  data['last_run'] = {
    'status'      => status,
    'finished_at' => Time.now.iso8601,
    'reason'      => reason
  }
  TB.save(LAST_RUN_PATH, data)
end
```

- [ ] **Step 7.5: Replace `:daily` task with preflight + record_run + notify wrap**

In `Rakefile`, replace the entire `desc 'Run the full daily pipeline across all sources'` + `task :daily do ... end` block (lines ~389 to ~469) with:

```ruby
desc 'Run the full daily pipeline across all sources'
task :daily do
  require 'bundler/setup'
  require 'date'
  require 'time'
  require 'json'
  # Hoist per-phase requires out of the source threads so concurrent first-require
  # races (autoload / constant resolution) cannot happen.
  require 'cloud_blog_collector'
  require 'tmpdir'
  require 'ruby_knowledge_store'
  require_relative 'lib/cloud_knowledge_db/esa_writer'
  require_relative 'lib/cloud_knowledge_db/esa_naming'
  require_relative 'lib/cloud_knowledge_db/daily_summarizer'

  CloudKnowledgeDb::Config.ensure_write_host!
  CloudKnowledgeDb::OllamaRunner.ensure_available!

  since, before = resolve_daily_window

  searcher  = CloudKnowledgeDb::EsaPreflight::DefaultSearcher.new(cfg: cfg)
  conflicts = CloudKnowledgeDb::EsaPreflight.conflicts(
    cfg: cfg, since: since, before: before, searcher: searcher
  )

  unless conflicts.empty? || ENV['CKDB_FORCE'] == '1'
    record_run('aborted', reason: "esa conflict: #{conflicts.size}件")
    CloudKnowledgeDb::Notifier.notify(status: 'aborted', reason: "esa conflict: #{conflicts.size}件")
    abort "=== daily aborted: esa conflicts ===\n#{JSON.pretty_generate(conflicts.map(&:to_h))}"
  end

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

    if (copy_to = cfg['db_copy_to'])
      src = File.expand_path(cfg['db_path'], __dir__)
      dst = File.expand_path(copy_to)
      CloudKnowledgeDb::DbSyncer.sync(source: src, destination: dst)
      puts "[sync] db copied to #{dst}"
    end

    record_run('ok')
    CloudKnowledgeDb::Notifier.notify(status: 'ok', since: since, before: before)
  rescue => e
    record_run('failed', reason: e.message[0, 200])
    CloudKnowledgeDb::Notifier.notify(status: 'failed', reason: e.class.name)
    raise
  end
end
```

Note: per-source thread internal `rescue` is preserved (a single source failing should not abort the run). The outer `begin..rescue` only triggers for catastrophic failures (DB lock, DbSyncer failure, etc.).

- [ ] **Step 7.6: Run full test suite to verify no regression**

```bash
bundle exec rake test
```

Expected: all tests pass (existing + new). The Rakefile :daily change is not directly unit-tested — it gets verified via end-to-end smoke test in Task 11.

- [ ] **Step 7.7: Verify the rake task list includes both `:plan` and the (preserved) `:daily`**

```bash
APP_ENV=test bundle exec rake -T | grep -E '^rake (plan|daily) '
```

Expected:
```
rake daily   # Run the full daily pipeline across all sources
rake plan    # preflight: list esa base_name conflicts (read-only)
```

- [ ] **Step 7.8: Commit GREEN**

```bash
git add Rakefile
git -c commit.gpgsign=false commit -m "feat: add esa preflight gate and last_run state recording to rake daily"
```

---

## Task 8: Update `.claude/agents/cloud-knowledge-db-run.md` for AUTOCONFIRM

`AUTOCONFIRM TASK=daily` token を新設して PLAN/CONFIRMED gate をスキップする。destructive task では拒否する。

**Files:**
- Modify: `.claude/agents/cloud-knowledge-db-run.md`

- [ ] **Step 8.1: Add `AUTOCONFIRM` mode section**

In `.claude/agents/cloud-knowledge-db-run.md`, in the `## Mode selection` section (around line 18-26), replace:

```markdown
## Mode selection

Parse the task prompt. Decide mode by these rules, in order:

1. **EXECUTE mode** — the prompt contains the literal token `CONFIRMED` (case-sensitive) AND all required parameters for the chosen task (e.g. `SINCE=`/`BEFORE=` for pipeline tasks, `DIR=` for per-phase tasks, `IDS=` for delete tasks).
2. **PLAN mode** — otherwise. Compute planned parameters and report. Do NOT execute any write-side task in PLAN mode.

If the prompt supplies parameters without `CONFIRMED`, still treat it as PLAN — echo the parameters for confirmation. Never assume consent.
```

with:

```markdown
## Mode selection

Parse the task prompt. Decide mode by these rules, in order:

1. **AUTOCONFIRM mode** — the prompt contains the literal token `AUTOCONFIRM` (case-sensitive) AND `TASK=daily`. This is the zero-touch fast path used by the router for the routine daily pipeline. SINCE/BEFORE are computed inside `rake daily` from the bookmark FLOOR; the subagent does not pre-compute them. **`AUTOCONFIRM` is rejected for any TASK other than `daily`** — destructive deletes and per-phase runs always require the PLAN/CONFIRMED two-stage gate.
2. **EXECUTE mode** — the prompt contains the literal token `CONFIRMED` (case-sensitive) AND all required parameters for the chosen task (e.g. `SINCE=`/`BEFORE=` for pipeline tasks, `DIR=` for per-phase tasks, `IDS=` for delete tasks).
3. **PLAN mode** — otherwise. Compute planned parameters and report. Do NOT execute any write-side task in PLAN mode.

If the prompt supplies parameters without `CONFIRMED` or `AUTOCONFIRM`, still treat it as PLAN — echo the parameters for confirmation. Never assume consent.
```

- [ ] **Step 8.2: Add an `AUTOCONFIRM mode` section before the `## EXECUTE mode` section (around line 151)**

Insert before `## EXECUTE mode`:

```markdown
## AUTOCONFIRM mode

Only reached when the prompt contains `AUTOCONFIRM TASK=daily`. This is the routine path for the user's daily zero-touch invocation.

1. Echo the confirmed parameters at the top:
   ```
   ## cloud-knowledge-db-run AUTOCONFIRM
   - TASK:    daily
   - APP_ENV: production (default unless overridden)
   ```
2. Verify ollama is up via the same preflight curl above. If not, stop and report — `rake daily` would fail anyway, no point burning the run.
3. Execute the task as a single foreground Bash call:
   ```bash
   cd /Users/bash/dev/src/github.com/bash0C7/cloud-knowledge-db && \
     APP_ENV=production bundle exec rake daily
   ```
   Use `timeout: 1800000` (30 min) — summary generation scales with article count.
4. Read the resulting `db/last_run.yml` to capture `last_run.status` (ok / aborted / failed) and `last_run.reason`.
5. Summarize:
   - **status=ok**: per-source `[timing]` breakdown, stored/skipped counts, posted esa numbers / URLs, WALLCLOCK, DB sync confirmation.
   - **status=aborted** (esa conflict): the conflicts JSON from rake's stdout (preserved by `abort`), plus the `last_run.reason`. Suggest follow-up: inspect existing posts, optionally `rake esa:delete IDS=...`, or rerun with `CKDB_FORCE=1`.
   - **status=failed**: the exception class and message, and the failing source key (from per-source `SKIP` lines in stdout). Suggest: rerun (most failures are transient and content_hash idempotency makes retry safe).
6. Do NOT run post-checks (`db:scan_pollution` / `db:scan_contamination` / `esa:find_duplicates`) automatically. AUTOCONFIRM mode is intentionally narrow — those are manual operations dispatched separately via the router.
7. Do NOT inject `CKDB_FORCE=1` autonomously. Force is a deliberate human decision; the router will pass it explicitly only when the user has approved it.

**Reject conditions** (return PLAN mode instead):
- `AUTOCONFIRM TASK=<anything other than daily>` → respond with: "AUTOCONFIRM is only supported for TASK=daily. Falling back to PLAN mode."
- `AUTOCONFIRM` together with `CKDB_FORCE=1` → respond with: "Force flag must be confirmed by the user, not via AUTOCONFIRM. Falling back to PLAN mode."
```

- [ ] **Step 8.3: Update the `## Why this shape` section to mention AUTOCONFIRM**

Replace the `## Why this shape` section's last paragraph with:

```markdown
## Why this shape

Write-side tasks are expensive (gemma4 inference, RSS + article enrichment HTTP fan-out, esa posting) or destructive (row / post deletion) and not trivially reversible. A two-phase plan/execute split with an explicit `CONFIRMED` gate makes the parameters auditable before any side effect. The main session cannot forward `CONFIRMED` without the user's actual approval, and you cannot fabricate consent you did not receive.

The `AUTOCONFIRM` fast path exists *only* for the routine daily pipeline, where the same SINCE/BEFORE computation is repeated every day and would only generate identical confirmation turns. Safety in this path is provided by `rake plan` / `rake daily` themselves — they refuse to run on esa conflicts unless `CKDB_FORCE=1` is set, they verify host and ollama, and any catastrophic failure is recorded to `db/last_run.yml` for the next invocation. Destructive tasks have no such safety net and therefore always require explicit confirmation.
```

- [ ] **Step 8.4: Commit**

```bash
git add .claude/agents/cloud-knowledge-db-run.md
git -c commit.gpgsign=false commit -m "feat(skill): add AUTOCONFIRM mode for zero-touch daily runs"
```

---

## Task 9: Update `.claude/commands/cloud-knowledge-db.md` for daily fast path

router の step 2 と step 5 に daily intent fast path を組み込む。それ以外の intent は既存挙動維持。

**Files:**
- Modify: `.claude/commands/cloud-knowledge-db.md`

- [ ] **Step 9.1: Add fast path branch to step 2**

Modify `.claude/commands/cloud-knowledge-db.md`. Replace the `### 2. Parse $ARGUMENTS to infer intent` section with:

```markdown
### 2. Parse `$ARGUMENTS` to infer intent

If `$ARGUMENTS` clearly names an operation (e.g. "daily", "rake 走らせて", "db:stats", "aws だけ", "削除して #135", "feed 生きてる？", "tasks 見せて"), skip to step 4 with that intent pre-filled.

If `$ARGUMENTS` is empty or ambiguous, go to step 3.

#### Daily fast path

If the parsed intent is **daily** — matching `daily`, `日々の最新化`, `普段の取り込み`, or `毎日の取り込み` — **skip step 3 and step 4 entirely** and go directly to dispatch with `AUTOCONFIRM`. This is the zero-touch routine path: the user has already opted into routine execution by invoking the skill with this intent, and re-asking for confirmation just adds a wasted turn.

For any other intent (per-phase / cleanup / triage / source-health / inspect / free-form), keep the existing step 3 / step 4 flow.
```

- [ ] **Step 9.2: Update dispatch section for daily fast path**

In the `### 5. Dispatch` section, modify the table to add a daily row above the menu choices:

```markdown
### 5. Dispatch

Based on the confirmed intent:

| Intent | Dispatch target |
|---|---|
| **daily fast path** | `cloud-knowledge-db-run` subagent with `AUTOCONFIRM TASK=daily APP_ENV=production` (single invocation, no PLAN/CONFIRMED) |
| 1. 取り込み (per-phase) | `cloud-knowledge-db-run` subagent (PLAN first, then CONFIRMED on approval) |
| 2. 確認      | `cloud-knowledge-db-inspect` subagent (direct, no gate) |
| 3. 掃除      | `cloud-knowledge-db-run` subagent (TASK=db:delete_polluted or esa:delete, PLAN then CONFIRMED) |
| 4. 分析      | `cloud-knowledge-db-pollution-triage` subagent (analysis only, no delete) |
| 5. feed健全性 | `cloud-knowledge-db-source-health` subagent (read-only) |
| 6. rake -T  | Print the `rake -T` output you already fetched in step 1 — no subagent |
| 7. その他    | Treat as free-form; re-ask clarification, or route to whichever subagent fits once clarified |
```

Then add a new subsection right above the existing "For `cloud-knowledge-db-run` dispatches (choices 1 and 3)" subsection:

```markdown
#### For the daily fast path

Single invocation, no PLAN cycle. Prompt template:

```
AUTOCONFIRM TASK=daily APP_ENV=production
[free-form context from the user, if any]
```

The subagent runs `bundle exec rake daily` directly. Whatever it returns (success summary, abort with esa conflicts, or failure with reason), relay verbatim to the user. If the result is `aborted`, follow up by offering options: inspect the conflicting esa post via `cloud-knowledge-db-inspect`, delete it via the `掃除` choice, or re-kick with `CKDB_FORCE=1` (which the user must confirm explicitly — do not auto-set it).

Never combine `AUTOCONFIRM` with destructive `TASK=` values. The subagent itself rejects this combination, but the router should not even construct such a prompt.
```

- [ ] **Step 9.3: Update Hard rules section to allow daily fast path**

Replace the "Never skip step 4" hard rule with:

```markdown
- **Never** skip step 4 (confirm understanding) **except** for the daily fast path described above. For per-phase / cleanup / triage / source-health / free-form intents, always echo back the interpretation before dispatching.
```

- [ ] **Step 9.4: Commit**

```bash
git add .claude/commands/cloud-knowledge-db.md
git -c commit.gpgsign=false commit -m "feat(skill): add daily fast path for zero-turn-roundtrip kickoff"
```

---

## Task 10: Run full test suite

すべての変更が green であること、既存テスト破壊なしを保証する。

- [ ] **Step 10.1: Run full test suite**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/cloud-knowledge-db && \
  APP_ENV=test bundle exec rake test
```

Expected: すべての既存テスト + 新規 `test_esa_token` / `test_esa_preflight` / `test_notifier` / `test_daily_pipeline` が pass。

- [ ] **Step 10.2: If any test fails, fix it before continuing**

If a test fails, analyze the failure, fix the root cause (do NOT skip / xfail), and re-run. Only proceed when the entire suite is green.

---

## Task 11: End-to-end smoke verification (manual, requires production host)

production host (`MacBook-Air-M3`) で実走確認する。これは自動 unit test の範疇ではない。

- [ ] **Step 11.1: Verify host**

```bash
scutil --get LocalHostName
```

Must print `MacBook-Air-M3`. If not, skip this task — smoke test only runs on the production host.

- [ ] **Step 11.2: Run `rake plan` against production**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/cloud-knowledge-db && \
  APP_ENV=production bundle exec rake plan
```

Expected: JSON output with `since`, `before`, and `conflicts` (likely empty if today's posts haven't been made yet, or containing today's posts if a daily already ran).

- [ ] **Step 11.3: Inspect `db/last_run.yml` after a daily run that has already happened today**

```bash
cat db/last_run.yml | grep -A3 last_run:
```

Expected (if no `:daily` ran with the new code yet): no `last_run` block. After the next daily run, expect `status: ok` (or `aborted` / `failed` accordingly), `finished_at: <ISO8601>`, `reason: ` field.

- [ ] **Step 11.4: Run an end-to-end daily kick via the skill (zero-touch)**

In a fresh terminal (or a fresh Claude Code session):

```bash
cd /Users/bash/dev/src/github.com/bash0C7/cloud-knowledge-db && \
  claude --model opus 'cloud-knowledge-db skill で 日々の最新化を実行しよう (production)'
```

Expected:
- The router enters the daily fast path (no "確認？" turn).
- The subagent dispatches `AUTOCONFIRM TASK=daily APP_ENV=production` and runs `rake daily` directly.
- After completion, an OS notification appears (`✓ daily ok` or `⚠ daily aborted` or `✗ daily failed`).
- `db/last_run.yml` has a fresh `last_run.status` reflecting the run outcome.
- The session prints a single summary and exits — no intermediate confirmation turn.

- [ ] **Step 11.5: Verify `last_run.yml`**

```bash
ruby -ryaml -e 'p YAML.load_file("db/last_run.yml")["last_run"]'
```

Expected: `{"status"=>"ok"|"aborted"|"failed", "finished_at"=>"<ISO8601>", "reason"=>nil|String}`.

If status is anything other than what the run produced, debug. Document any deviation from the expected behavior.

---

## Task 12: Update CLAUDE.md

新しい lib responsibilities、`last_run` セクション、`CKDB_FORCE`、`rake plan` を README/CLAUDE.md に追記する。

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 12.1: Update `lib/ responsibilities` table**

In `CLAUDE.md`, find the `### lib/ responsibilities` section. Add three new rows:

```markdown
| `lib/cloud_knowledge_db/esa_token.rb` | keychain (`security`) から `esa-mcp-token` を取得する shared module。`EsaWriter` / `EsaPreflight::DefaultSearcher` から呼ばれる |
| `lib/cloud_knowledge_db/esa_preflight.rb` | `Conflict` struct + `EsaPreflight.conflicts(cfg:, since:, before:, searcher:)` + `DefaultSearcher` (live esa API) / `StubSearcher` (test 用) |
| `lib/cloud_knowledge_db/notifier.rb` | `Notifier.notify(status: ok\|aborted\|failed, since:, before:, reason:)` で macOS osascript display notification |
```

- [ ] **Step 12.2: Update `Rake Tasks` section**

In `CLAUDE.md`, find the `## Rake Tasks` section and add:

```markdown
# Preflight (read-only): esa base_name 衝突 list を JSON で出す
APP_ENV=production bundle exec rake plan
APP_ENV=production bundle exec rake plan SINCE=2026-04-29 BEFORE=2026-04-30
```

In the same section, update the daily example to mention AUTOCONFIRM:

```markdown
# Daily (auto SINCE/BEFORE from bookmark, esa conflict preflight + last_run.yml status recording)
APP_ENV=production bundle exec rake daily
APP_ENV=production CKDB_FORCE=1 bundle exec rake daily   # esa conflict gate を bypass
```

- [ ] **Step 12.3: Add `last_run` section to bookmark documentation**

Find the `## Two-Stage Bookmark` section. After the existing yaml example, add:

```markdown
さらに rake daily 完了時に global な `last_run` セクションが書かれる:

```yaml
last_run:
  status: ok                          # ok | aborted | failed
  finished_at: 2026-04-30T09:08:30+09:00
  reason: nil                         # aborted/failed 時に短文（例: "esa conflict: 2件"）
```

- `status: aborted` は esa preflight で `EsaPreflight.conflicts` が衝突を返した時。`CKDB_FORCE=1` で bypass 可。
- `status: failed` は per-source rescue で吸収できないトップレベル例外（DB lock / DbSyncer 失敗 等）。次回 kick で content_hash idempotent に自動再試行される想定。
```

- [ ] **Step 12.4: Add `CKDB_FORCE` to host guard / env section**

Find the `## Host Guard` section. After the existing `ALLOW_WRITE=1` mention, add:

```markdown
**`CKDB_FORCE=1`** は別の escape hatch で、`rake daily` の **esa preflight gate** を bypass する用途。host guard とは独立。esa 衝突があると分かっていて意図的に上書き / suffix 投稿させたい時にのみ使う。
```

- [ ] **Step 12.5: Run final test suite**

```bash
bundle exec rake test
```

Expected: all green.

- [ ] **Step 12.6: Commit**

```bash
git add CLAUDE.md
git -c commit.gpgsign=false commit -m "docs: document esa_preflight, notifier, last_run section, CKDB_FORCE"
```

---

## Self-Review Checklist (run after writing the plan)

**Spec coverage:**
- [x] Goal 1 (zero-touch daily) — Tasks 8, 9, 11
- [x] Goal 2 (esa conflict prevention) — Tasks 2, 3, 4, 7
- [x] Goal 3 (last_run.yml records ok/aborted/failed) — Tasks 7, 12
- [x] Goal 4 (osascript notification) — Tasks 5, 7
- [x] Goal 5 (next-kick retry, no in-run retry) — design preserved in Task 7's per-source rescue, no extra implementation
- [x] Non-goal: post-check kept manual — Task 8's AUTOCONFIRM section explicitly excludes them
- [x] Non-goal: no degraded health — only `last_run.status` 3-value, no `health` block
- [x] Non-goal: no preflight for host/ollama/WIP/SINCE/floor beyond rake daily's existing internal raises — Task 7 keeps existing `Config.ensure_write_host!` / `OllamaRunner.ensure_available!` calls in place, no new gating

**Placeholder scan:** None. All code is written out, all paths are exact, all commands are runnable.

**Type consistency:**
- `EsaPreflight.conflicts(cfg:, since:, before:, searcher:)` — used consistently in Tasks 2, 3, 4, 6, 7.
- `EsaPreflight::DefaultSearcher.new(cfg:, token: nil, http_runner: nil)` — used consistently in Tasks 4, 6, 7.
- `Notifier.notify(status:, since: nil, before: nil, reason: nil, runner: nil)` — used consistently in Tasks 5, 7.
- `record_run(status, reason: nil)` — used consistently in Tasks 7, 11, 12.
- `EsaToken.fetch(runner: nil)` — used consistently in Tasks 1, 4.
- `last_run.yml` shape (`status`, `finished_at`, `reason`) — same across Tasks 7, 11, 12.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-30-daily-automation.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
