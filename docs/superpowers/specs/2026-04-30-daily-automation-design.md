# daily 自動化 (人間介在ゼロ完走)

作成日: 2026-04-30

## 背景

- 現状 `rake daily` は `cloud-knowledge-db` skill 経由で実行する際に router の「確認？」と subagent の `PLAN` / `CONFIRMED` gate を経由しており、kick から完走まで 2〜3 ターン人手を要する。
- 普段の運用は決まった host (`MacBook-Air-M3`) で `claude --model opus 'cloud-knowledge-db skill で 日々の最新化を実行しよう (production)'` を叩く形に固定されており、毎回同じ確認を返すだけのターンが冗長。
- 兄弟リポ `ruby-knowledge-db` には `PipelinePlan` + `EsaPreflight` による preflight + `RKDB_FORCE` の escape hatch があり、人間介在を最小化する仕組みが先行して整備されている。
- 失敗ケースは `content_hash` UNIQUE と二段 bookmark によりリトライで自然回復する設計が既に入っており、特別なリカバリー機構は要らない。**事前に防ぎたいのは esa 二重投稿だけ**。

## ゴール

1. ユーザーが kick した後、daily の正常系では一切のターン往復なしに完走する。
2. esa の base_name 衝突は事前に検知して abort する (二重投稿の事故を防ぐ)。
3. 完走 / 失敗 / abort の状況が `db/last_run.yml` に 1 行記録され、人間が後から状況を把握できる。
4. 完走 / 失敗 / abort いずれの場合も OS 通知 (osascript) で kick 直後にも気付ける。
5. abort / failure 時は次回 kick で content_hash idempotency に頼って自動再試行されることを前提とし、追加の retry 機構は持たない。

## 非ゴール

- post-check (`db:scan_pollution` / `db:scan_contamination` / `esa:find_duplicates`) を daily 内で自動実行しない。これらは従来通り skill 経由の手動運用とする。
- `health: degraded` のような複合状態を yml に記録しない。状況は `ok` / `aborted` / `failed` の 3 値で管理する。
- preflight で host / ollama / WIP / SINCE-BEFORE / floor 整合などを個別検査しない。これらは `rake daily` 内部の既存例外でカバーし、失敗したら次回 kick でリトライする。
- 自動 triage / 自動削除はやらない。汚染やデータ不整合は手動で `cloud-knowledge-db-pollution-triage` 経由で扱う。
- daily 以外の task (`fetch:*` / `import:*` / `esa:*` / destructive cleanup) を介在ゼロ化しない。これらは従来の `PLAN` / `CONFIRMED` gate を維持する。

## アーキテクチャ概要

```
lib/cloud_knowledge_db/
├── (新規) esa_preflight.rb   - live esa API で base_name 衝突検出
├── (新規) notifier.rb        - osascript ラッパー (ok / aborted / failed)
├── (現状維持) その他
```

`rake daily` が `EsaPreflight.conflicts` を冒頭で 1 回呼び、衝突があれば `record_run('aborted', ...)` + `Notifier.notify` の上 abort。衝突無しなら従来の per-source thread 並列パイプラインを実行し、終端で `record_run('ok')` + 通知。例外発生時は `rescue` で `record_run('failed', ...)` + 通知の上 raise。

skill 側は router の daily intent に fast path を足し、subagent に `AUTOCONFIRM TASK=daily` token を新設する。

## 変更内容

### A. `lib/cloud_knowledge_db/esa_preflight.rb` (新規)

責務: 区間 `[since, before)` × official 4 source の base_name について、live esa API GET で既存 post を検索し衝突を返す。`ruby-knowledge-db` の `EsaPreflight` と同シグネチャ・同パターン。

```ruby
module CloudKnowledgeDb
  module EsaPreflight
    Conflict = Struct.new(:source, :date, :name, :category,
                          :existing_post_number, :existing_post_url,
                          keyword_init: true)

    SHORT_NAMES = {
      'aws_blog'    => 'aws',
      'gcp_blog'    => 'gcp',
      'gws_blog'    => 'gws',
      'gitlab_blog' => 'gitlab'
    }.freeze

    def self.conflicts(cfg:, since:, before:, searcher:)
      results = []
      team            = cfg.dig('esa', 'team')
      category_prefix = cfg.dig('esa', 'category_prefix')

      SHORT_NAMES.each do |source_key, short|
        (since...before).each do |date|
          name     = "#{date}-#{short}-cloud-changes"
          category = "#{category_prefix}/#{short}/#{date.strftime('%Y/%m/%d')}"
          searcher.search(team: team, category: category, name: name).each do |p|
            results << Conflict.new(
              source: source_key, date: date.to_s,
              name: name, category: category,
              existing_post_number: p['number'],
              existing_post_url:    p['url']
            )
          end
        end
      end
      results
    end

    class DefaultSearcher
      def initialize(cfg)
        @cfg   = cfg
        @token = fetch_token_from_keychain   # 既存 EsaWriter と同じ経路
      end

      def search(team:, category:, name:)
        # GET https://api.esa.io/v1/teams/{team}/posts?q=category:{category}+name:{name}
        # Authorization: Bearer {token}
        # 2xx -> JSON parse して posts 配列返す
        # 4xx/5xx -> raise (PipelinePlan 不在の今回設計では、Rakefile の rescue が拾う)
      end
    end

    class StubSearcher
      def initialize(posts_by_query = {}) ; @posts = posts_by_query ; end
      def search(team:, category:, name:) ; @posts.fetch([team, category, name], []) ; end
    end
  end
end
```

実装規約:

- 区間は半開 `(since...before)` で per day 反復。`before - since == 1` のとき API call 数 = official 4 source × 1 day = **4 calls**。
- token 取得は既存 `EsaWriter` のロジックを class method or module method で共有。
- `DefaultSearcher#search` の HTTP 失敗は raise、`Rakefile :daily` の rescue で `failed` として記録される。
- classmethod は esa 投稿対象外なので `SHORT_NAMES` に含めない。

### B. `lib/cloud_knowledge_db/notifier.rb` (新規)

責務: macOS の通知センターに 1 行表示する。ok / aborted / failed の 3 status 対応。通知失敗で daily 全体を破壊しない。

```ruby
module CloudKnowledgeDb
  module Notifier
    TITLES = {
      'ok'      => '✓ daily ok',
      'aborted' => '⚠ daily aborted',
      'failed'  => '✗ daily failed'
    }.freeze

    def self.notify(status:, since: nil, before: nil, reason: nil)
      title = TITLES.fetch(status)
      body  = reason || "[#{since}, #{before})"
      system('osascript', '-e', %Q(display notification "#{body}" with title "#{title}"))
    rescue => e
      warn "[notifier] failed: #{e.message}"
    end
  end
end
```

### C. `db/last_run.yml` の `last_run` セクション (新規)

global セクションを 1 つ追加する。per-source ブロックは変更しない。

```yaml
aws_blog: { last_started_at: ..., last_completed_at: ..., ... }   # 既存
gcp_blog: { ... }                                                 # 既存
# ...

last_run:
  status: ok                          # ok | aborted | failed
  finished_at: 2026-04-30T09:08:30+09:00
  reason: nil                         # aborted/failed 時の 1 行短文 (省略可)
```

`record_run(status, reason: nil)` ヘルパー (Rakefile top-level method) が `last_run` セクション全体を差し替える。書き込みは既存の `TrunkBookmark.load` / `save` 経路を流用。`reason` は `nil` でも OK、yml には `reason: ` で出る。

### D. Rakefile (改造)

追加 `require`:

```ruby
require_relative 'lib/cloud_knowledge_db/esa_preflight'
require_relative 'lib/cloud_knowledge_db/notifier'
```

新規 task `:plan`:

```ruby
desc 'preflight: list esa base_name conflicts (read-only)'
task :plan do
  cfg = CloudKnowledgeDb::Config.load
  since_d, before_d = resolve_window(cfg)
  searcher  = CloudKnowledgeDb::EsaPreflight::DefaultSearcher.new(cfg)
  conflicts = CloudKnowledgeDb::EsaPreflight.conflicts(
    cfg: cfg, since: since_d, before: before_d, searcher: searcher
  )
  puts JSON.pretty_generate(
    since: since_d.to_s, before: before_d.to_s,
    conflicts: conflicts.map(&:to_h)
  )
end
```

改造 task `:daily`:

```ruby
desc 'Run the full daily pipeline across all sources'
task :daily do
  cfg = CloudKnowledgeDb::Config.load
  since_d, before_d = resolve_window(cfg)

  searcher  = CloudKnowledgeDb::EsaPreflight::DefaultSearcher.new(cfg)
  conflicts = CloudKnowledgeDb::EsaPreflight.conflicts(
    cfg: cfg, since: since_d, before: before_d, searcher: searcher
  )

  unless conflicts.empty? || ENV['CKDB_FORCE'] == '1'
    record_run('aborted', reason: "esa conflict: #{conflicts.size}件")
    CloudKnowledgeDb::Notifier.notify(status: 'aborted', reason: "esa conflict: #{conflicts.size}件")
    abort "=== daily aborted: esa conflicts ===\n#{JSON.pretty_generate(conflicts.map(&:to_h))}"
  end

  run_all_sources(since_d, before_d)        # 既存の per-source thread 並列パイプライン
  sync_db_to_destination(cfg)               # 既存の DbSyncer.sync 呼び出し
  record_run('ok')
  CloudKnowledgeDb::Notifier.notify(status: 'ok', since: since_d, before: before_d)
rescue => e
  record_run('failed', reason: e.message[0, 200])
  CloudKnowledgeDb::Notifier.notify(status: 'failed', reason: e.class.name)
  raise
end

def resolve_window(cfg)
  before_str = ENV['BEFORE'] || Date.today.to_s
  since_str  = ENV['SINCE']
  if since_str.nil?
    data        = CloudKnowledgeDb::TrunkBookmark.load(LAST_RUN_PATH)
    source_keys = cfg.fetch('sources').keys
    floor       = CloudKnowledgeDb::TrunkBookmark.recommended_since_floor(data, source_keys)
    since_str   = floor || (Date.today - 1).to_s
  end
  [Date.parse(since_str), Date.parse(before_str)]
end

def record_run(status, reason: nil)
  data = CloudKnowledgeDb::TrunkBookmark.load(LAST_RUN_PATH)
  data['last_run'] = {
    'status'      => status,
    'finished_at' => Time.now.iso8601,
    'reason'      => reason
  }
  CloudKnowledgeDb::TrunkBookmark.save(LAST_RUN_PATH, data)
end
```

ポイント:

- `:daily` 全体を 1 個の `begin..rescue` で囲み、shorthand `rescue => e` で末尾。ネスト深さ 1。
- `run_all_sources` / `sync_db_to_destination` は既存 Rakefile body を helper に切り出すだけで、内部ロジックは変更しない。
- `resolve_window` は既存のロジックを集約。bookmark FLOOR が nil のときの fallback (yesterday) も既存通り。
- `CKDB_FORCE=1` は esa 衝突 gate のみを bypass する。他の例外 (host guard / ollama / DB I/O 失敗) は force しても突破できない (既存 `Config.ensure_write_host!` / `OllamaRunner.ensure_available!` が daily 内部で raise する)。

### E. `.claude/commands/cloud-knowledge-db.md` (改造)

router の step 2「intent 解釈」に **daily fast path** 分岐を追加。

```markdown
### daily intent fast path

`日々の最新化` / `普段の取り込み` / `daily` のいずれかにマッチした場合:

1. step 3 (menu 提示) と step 4 (確認？) をスキップする。
2. `cloud-knowledge-db-run` を `AUTOCONFIRM TASK=daily APP_ENV=production` で dispatch する。
3. subagent から返ってきた summary をユーザーにそのまま relay する。

それ以外の intent (fetch:* / import:* / esa:* / cleanup / triage / source-health / 自由入力) は **既存フロー維持** (step 4 の確認、PLAN gate、CONFIRMED 再 dispatch)。
```

### F. `.claude/agents/cloud-knowledge-db-run.md` (改造)

prompt token を 3 種類に拡張。

```markdown
## prompt token

### `AUTOCONFIRM TASK=daily [APP_ENV=production]` (新規)

daily 専用 fast path。

**規約**:
- `TASK=daily` 以外の値が来たら拒否し、PLAN モードに格下げする (`AUTOCONFIRM TASK=db:delete_polluted` などは禁止)。
- `CKDB_FORCE=1` は AUTOCONFIRM 経由では付けない (force は人手判断のみ)。

**実行手順**:
1. `bundle exec rake daily` を実行する (rake 内部で preflight が走る、PLAN は呼ばない)。
2. 完走したら main session に summary を返す:
   - `last_run.yml` の `last_run.status` (ok / aborted / failed)
   - 完走時: 各 source の取り込み件数、esa 投稿 URL、bookmark 進捗、DB sync 成否
   - aborted 時: rake daily の stdout (conflicts JSON) を整形して返す
   - failed 時: `last_run.reason` と例外 backtrace の summary

### `TASK=...` (既存 / 変更なし)

PLAN モード。fetch:* / import:* / esa:* / 等で使う。

### `CONFIRMED TASK=...` (既存 / 変更なし)

EXECUTE モード。destructive (db:delete_polluted / esa:delete) を含む全タスクで利用可。
```

abort / failed 受領時の main session 側の挙動は **テンプレート化せず、状況を見て普通に対応**:

- `aborted` (esa conflicts) → conflicts list を見せて、ユーザーに「既存 post を確認、不要なら delete、要らないなら `CKDB_FORCE=1` で再 kick、提案？」と聞く。
- `failed` (例外) → reason を見せて、「次回 kick でリトライしたら直る可能性が高いで、確認？」と案内。

## 失敗・リカバリー方針

| 異常 | 完走中の挙動 | リカバリー |
|---|---|---|
| per-source の fetch / import / esa 例外 | 既存の per-source rescue で他 source 続行、failed source は bookmark を進めない | **次回 kick で同区間を自動再 fetch**。`content_hash` UNIQUE で重複なし、idempotent |
| `rake daily` 全体が catastrophic に失敗 (DB lock / disk full / DbSyncer 失敗) | top-level rescue で `record_run('failed', reason: ...)` + 通知の上 raise | 次回 kick で再試行。原因が外部要因 (ollama 落ちてる等) なら復旧後に kick |
| esa 衝突 (preflight 検知) | `record_run('aborted', ...)` + 通知 + abort | ユーザー判断: 既存 post 削除 → 再 kick / `CKDB_FORCE=1` で強行 / bookmark 直し |
| Notifier 自身の失敗 | shorthand rescue で warn のみ、daily の status には影響しない | 次回通知で復旧 |

## テスト戦略

新規 / 改造ファイルそれぞれに test を追加する。test 命名は `test_<state>_<expected>` 形式 (`ruby-knowledge-db` 慣習)。

### `test/test_esa_preflight.rb` (新規)

- `test_no_conflicts_returns_empty`: StubSearcher が `[]` 返す → results 空。
- `test_one_conflict_per_source_per_day`: aws 2026-04-29 だけ post を返す → Conflict 1 件。
- `test_multi_day_window_expands`: SINCE=2026-04-25 BEFORE=2026-04-30 → 5 day × 4 source 分 search 呼ばれる (Stub の call count で検証)。
- `test_classmethod_excluded`: classmethod_blog は SHORT_NAMES に含まれず search されない。
- `test_default_searcher_token_fetched_from_keychain`: token 取得経路の interface 検証 (実 API は叩かない)。
- `test_default_searcher_4xx_raises`: HTTP 403 を返す stub HTTP client → 例外伝播。

### `test/test_notifier.rb` (新規)

- `test_notify_ok_calls_osascript_with_ok_title`: system 呼び出しを stub し title が `✓ daily ok`。
- `test_notify_aborted_uses_reason_as_body`: reason が body に入る。
- `test_notify_failed_does_not_raise_when_osascript_missing`: system が false 返しても rescue で warn のみ。
- `test_notify_unknown_status_raises_keyerror`: TITLES.fetch が KeyError。

### `test/test_daily_pipeline.rb` (新規)

- `test_record_run_ok_writes_status_finished_at`: yml に status=ok と finished_at が書かれる。
- `test_record_run_aborted_writes_reason`: reason が yml に出る。
- `test_record_run_failed_truncates_long_reason`: 200 字超の reason は truncate される。
- `test_daily_aborts_when_esa_conflict_exists`: StubSearcher が conflict 返す → record_run('aborted') + abort。
- `test_daily_skips_preflight_when_force_env_set`: `CKDB_FORCE=1` で conflict あっても突破。
- (既存 daily の挙動を破らない確認は既存 test に任せる、追加 test は preflight + record_run の経路に絞る。)

## 実装順序 (build sequence)

依存順に並べる。各ステップでテスト red → green → 必要なら refactor (t-wada TDD)。

1. **`EsaPreflight` 単体** (`lib` + `test`) — 衝突検出ロジックの確定。skill / rake からは触らずユニットだけ。
2. **`Notifier` 単体** (`lib` + `test`) — osascript 呼び出しの interface 確定。
3. **Rakefile 改造** — `:plan` 新設、`:daily` に preflight gate と record_run / notify を組み込み。`run_all_sources` / `sync_db_to_destination` / `resolve_window` を helper に切り出す (既存 daily の挙動は変えない)。
4. **rake test 全体 green 確認** — 既存テストが破壊されていないことを確認。
5. **手動 production smoke test** — `APP_ENV=production bundle exec rake plan` で JSON が出ることを確認 (read-only なので副作用なし)。
6. **skill 改造** — router の daily fast path、subagent の AUTOCONFIRM token を追記。
7. **end-to-end 実走** — `claude --model opus 'cloud-knowledge-db skill で 日々の最新化を実行しよう (production)'` を 1 回叩いてターン往復ゼロで完走することを確認。
8. **CLAUDE.md 更新** — 新規 file 責務と `last_run` セクションの説明を追加。

## 環境変数まとめ

| ENV | 役割 | 用法 |
|---|---|---|
| `APP_ENV` | development / test / production 切替 (既存) | 通常 production |
| `SINCE` / `BEFORE` | 区間の explicit override (既存) | 通常は bookmark FLOOR 自動計算で OK |
| `CKDB_FORCE=1` | esa 衝突 gate の bypass (新規) | 既存 esa post を意図的に上書き / suffix 投稿させたい時のみ |

## 参考

- `ruby-knowledge-db` の `lib/ruby_knowledge_db/esa_preflight.rb` および `lib/ruby_knowledge_db/pipeline_plan.rb` の `EsaPreflight` 利用箇所。
- 本リポ `lib/cloud_knowledge_db/esa_writer.rb` の token 取得経路 (`security find-generic-password`)。
- 本リポ `lib/cloud_knowledge_db/trunk_bookmark.rb` の `load` / `save` / `recommended_since_floor`。
