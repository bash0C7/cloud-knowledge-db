# cloud-knowledge-db 設計仕様

- **作成日**: 2026-04-16
- **対象**: cloud-knowledge-db プロジェクト初期設計
- **位置付け**: ruby-knowledge-db のクラウド版。AWS / Google Cloud / Google Workspace / GitLab 公式blog を SSOT として SQLite に集約し、デイリーで esa に投稿、chiebukuro-mcp 経由で対話深掘り可能にする。
- **言語**: Ruby 4.0系（CRuby）

---

## 1. 目的とスコープ

### 1.1 目的
クラウドプラットフォームの公式blogを日次で収集・翻訳・要約・検索可能化し、
個人用のローカル AI データエージェントから対話深掘りできるようにする。

### 1.2 範囲内
- 公式4ソースの英語版blog: AWS / Google Cloud / Google Workspace / GitLab
- 補助ソース: classmethod.jp（DB格納のみ、esa投稿対象外）
- 英→日 Haiku 翻訳（API 直叩き、CLI 不使用）
- 日次 esa 投稿（公式4ソースのみ、ソース別記事形式）
- chiebukuro-mcp への DB 登録 + meta_patches 連携
- ローカル subagent 3つ: daily / pollution-triage / source-health
- 二段 bookmark + ホストガード + 汚染検知

### 1.3 範囲外（v2 以降）
- 多言語他サイト（Microsoft Azure / IBM Cloud 等）— adapter追加で拡張可能な設計に留める
- WebSocket/SSE リアルタイム取り込み
- 翻訳品質の自動評価ループ（BLEU 等）
- 横断1記事ダイジェスト形式（採用せず、ソース別記事形式を採用）
- 複数 Mac 同時書込み対応（host guard で単一 Mac 運用に制限）
- chiebukuro-mcp 側の write tool 追加（chiebukuro-mcp は読み取り専用責務）

---

## 2. アーキテクチャ全体像

### 2.1 リポジトリ構造（軽分割）

```
~/dev/src/github.com/bash0C7/
├── cloud-knowledge-db/         （このrepo・orchestrator）
├── cloud-blog-collector/       （新規 gem・1つだけ。adapter pattern 内包）
└── ruby-knowledge-store/       （既存・流用。memories + memories_vec + memories_fts + _sqlite_mcp_meta）
```

### 2.2 設計原則

- **SSOT**: 公式blog（英語版）が唯一の真実。英語が最新、日本語版は派生。
- **DB再生成可能**: 英語原文が残る限り再翻訳で復元可能。
- **責任境界明確**: orchestrator は実行統合のみ。collector は取得のみ。store は永続化のみ。
- **chiebukuro-mcp 連携は読み取り専用**: 書き込みはこのrepo、読みは chiebukuro-mcp。

### 2.3 ソース → 取得方式マッピング（暫定）

| ソース | URL | Tier | source 値 |
|---|---|---|---|
| AWS News (英語) | `aws.amazon.com/blogs/aws/feed/` | RSS | `aws/blogs/news` |
| Google Cloud (英語) | `cloud.google.com/blog/products/gcp/rss` | RSS | `gcp/blogs/products` |
| Google Workspace (英語) | `workspace.google.com/blog/rss` | RSS | `gws/blogs/all` |
| GitLab (英語) | `about.gitlab.com/atom.xml` | ATOM | `gitlab/blogs/all` |
| classmethod (補助、日本語) | `dev.classmethod.jp/feed` | RSS+tagフィルタ | `{aws,gcp,gws,gitlab}/classmethod` |

**source 命名規約**: 全ソースで provider を最上位プレフィックスに統一（`aws/...`, `gcp/...`, `gws/...`, `gitlab/...`）。これにより `WHERE source LIKE 'aws/%'` で AWS 関連（公式 + classmethod + 原文）を一掃できる。

URL 確定は実装時に WebFetch で生存確認、必要なら Tier 昇格（RSS → WebFetch → Chrome）。

---

## 3. コンポーネント

### 3.1 cloud-blog-collector gem（新規）

統一インターフェース（ruby-knowledge-db の Collector 規約踏襲）：

```ruby
module CloudBlogCollector
  class Collector
    SOURCE_PREFIX = "aws"  # 等

    def initialize(config)  # config: sources.yml entry
    end

    # @param since [Time, nil] 前回完了時刻
    # @param before [Time, nil] 半開区間の上限（fetch は before 未満）
    # @return [Array<Hash>] [{url, title, content_original, published_at, source}, ...]
    def fetch(since:, before:)
    end
  end
end
```

#### adapters/

| adapter | 用途 |
|---|---|
| `RssAdapter` | RSS/ATOM を `rss` gem または `nokogiri` でパース。最も一般的 |
| `WebFetchAdapter` | `Faraday` + `nokogiri` で HTML scraping。RSS なし/不完全な blog 用 |
| `ChromeAdapter` | chrome-mcp 経由。JS レンダ必要な blog 用、最終手段 |
| `ClassmethodAdapter` | RSS 取得後 `<category>` タグで AWS/GCP/GWS/GitLab に分類して source 細分化 |

#### source_registry

`sources.yml` の各ソースに `adapter:` キーを持たせ、Tier 昇格は YAML 1行変更で完結。

### 3.2 cloud-knowledge-db orchestrator

| ファイル | 責務 |
|---|---|
| `lib/cloud_knowledge_db/orchestrator.rb` | 全ソース fetch→translate→import→esa の統合実行 |
| `lib/cloud_knowledge_db/translator.rb` | Anthropic SDK 直叩きで Haiku 翻訳。**system prompt は英語、CLAUDE.md 非継承** |
| `lib/cloud_knowledge_db/daily_summarizer.rb` | esa 投稿用本文生成。Anthropic SDK 直叩き、Opus |
| `lib/cloud_knowledge_db/content_classifier.rb` | classmethod 記事のタグ分類、Haiku |
| `lib/cloud_knowledge_db/esa_writer.rb` | esa API 投稿（ruby-knowledge-db からコピー流用） |
| `lib/cloud_knowledge_db/trunk_bookmark.rb` | 二段 bookmark 管理（ruby-knowledge-db からコピー） |
| `lib/cloud_knowledge_db/host_guard.rb` | LocalHostName チェック（ruby-knowledge-db からコピー） |
| `lib/cloud_knowledge_db/model_resolver.rb` | runtime model resolve（後述） |
| `lib/cloud_knowledge_db/config.rb` | APP_ENV 別設定ロード |

### 3.3 ruby-knowledge-store gem（既存・流用）

スキーマ追加なし。既存の memories + memories_vec + memories_fts + _sqlite_mcp_meta をそのまま使う。

### 3.4 DB スキーマ: 1記事=2レコード方式（α 案採用）

| レコード | source 値の例 | content |
|---|---|---|
| 翻訳済み | `aws/blogs/news` | 日本語訳 |
| 原文 | `aws/blogs/news/original` | 英語原文 |

- 両方に embedding を付与（日本語クエリも英語クエリも引ける）
- 紐付けは frontmatter の `url` で行う（必要に応じて metadata JSON カラム検討、初版はファイル名 slug で対応）
- store gem スキーマ変更なし（責任境界維持）

---

## 4. データフロー（4-phase pipeline）

### 4.1 Phase 構造

```
Phase 1a (fetch)     RSS/Atom/Web → 英語原文 MD 群を tmpdir に出力
                          ↓
Phase 1b (translate) tmpdir 英語MD → Haiku 翻訳 → tmpdir に日本語MD 追加
                          ↓
Phase 2a (import)    tmpdir 全 MD → SQLite（content_hash 冪等）
                          ↓
Phase 2b (esa)       日本語MD のみ → esa API（WIP/カテゴリ規約）
```

### 4.2 Rake タスク命名

```bash
# Phase 別個別実行
APP_ENV=test SINCE=2026-04-15 BEFORE=2026-04-16 bundle exec rake fetch:aws
# => DIR=/var/folders/.../aws_..._2026-04-15_2026-04-16
APP_ENV=test DIR=$DIR bundle exec rake translate:aws
APP_ENV=test DIR=$DIR bundle exec rake import:aws
APP_ENV=test DIR=$DIR bundle exec rake esa:aws

# 一括（昨日分自動）
APP_ENV=production bundle exec rake daily
```

`*_blog` キー（`aws_blog`, `gcp_blog`, `gws_blog`, `gitlab_blog`, `classmethod_blog`）から Rake タスク自動生成。`classmethod_blog` のみ `esa:` タスクをスキップ（Q4=B 採用）。

### 4.3 tmpdir 出力ファイル名規約

```
{tmpdir}/
  2026-04-15-aws-original-{slug}.md   # 英語原文（YAML frontmatter: url, published_at, source）
  2026-04-15-aws-{slug}.md            # 日本語訳（同 frontmatter + translated_at）
```

slug は URL の path 末尾、または hash の先頭8桁。

### 4.4 Phase 別冪等性

| Phase | 冪等戦略 |
|---|---|
| fetch | `since/before` 区間 + `published_at` フィルタで決定論的。同じ区間で再実行しても同じ MD 群 |
| translate | 翻訳済み MD があれば skip（タイムスタンプ比較）。未翻訳のみ Haiku 呼び出し |
| import | `content_hash` UNIQUE INDEX で重複自動 skip（既存 store gem の仕様） |
| esa | フルパス決定論。同名なら `(1)` 重複検知対象 |

### 4.5 二段 bookmark（ruby-knowledge-db 同型）

`db/last_run.yml`:
```yaml
aws_blog:
  last_started_at:       2026-04-16T09:00:00+09:00
  last_started_before:   2026-04-16
  last_completed_at:     2026-04-16T09:08:00+09:00
  last_completed_before: 2026-04-16
  models_used:                                     # 実証可能性のため記録
    translator:       claude-haiku-4-5-20251001
    daily_summarizer: claude-opus-4-6
gcp_blog: { ... }
gws_blog: { ... }
gitlab_blog: { ... }
classmethod_blog: { ... }
```

WIP 判定・FLOOR 算出は ruby-knowledge-db の `trunk_bookmark.rb` をコピー流用。

### 4.6 esa カテゴリ命名

```
{env_prefix}/cloud-trunk-changes/{source_short}/{yyyy}/{mm}/{dd}/{yyyy-mm-dd}-{source_short}-cloud-changes
例: production/cloud-trunk-changes/aws/2026/04/16/2026-04-16-aws-cloud-changes
```

source_short: `aws_blog → aws`, `gcp_blog → gcp`, `gws_blog → gws`, `gitlab_blog → gitlab`。

### 4.7 新着ゼロ日の扱い

- fetch 返り値が空 → translate / import / esa すべて skip して bookmark のみ更新
- esa に「変更なし」記事は投稿しない（汚染防止）
- skip 理由は stdout / log にだけ残す

---

## 5. chiebukuro-mcp 連携

### 5.1 登録手順

1. `~/chiebukuro-mcp/chiebukuro.json` の `databases` キーに追加：

```json
"cloud_knowledge": {
  "path": "/Users/bash/Library/Mobile Documents/com~apple~CloudDocs/chiebukuro-mcp/db/cloud_knowledge.db",
  "description": "AWS/Google Cloud/Google Workspace/GitLab 公式blog 日次収集 DB。英語原文（source=*/original）と日本語訳（Haiku）を両方格納。classmethod.jpの解説記事も補強用に格納。詳細は schema:// / recipes:// / hints:// 参照。",
  "semantic_search": {
    "vec_table": "memories_vec",
    "content_table": "memories",
    "content_column": "content",
    "source_column": "source",
    "join_key": "memory_id"
  }
}
```

2. dotfiles の meta_patches に `cloud_knowledge.yml` 配置 → `apply_meta_patches.rb` 実行で `_sqlite_mcp_meta` 反映。

### 5.2 meta_patches/cloud_knowledge.yml

```yaml
db_description: |
  AWS / Google Cloud / Google Workspace / GitLab 公式blog の日次収集 DB。
  英語原文（source 末尾 /original）+ Haiku 翻訳済み日本語版を両方格納。
  classmethod.jp の解説記事も補強用に4タグ別 source で格納（esa 投稿対象外）。

tables:
  - name: memories
    description: "blog 記事本体。source で配信元/言語を識別、metadata で url/published_at をJSON保持。"
  - name: memories_vec
    description: "memories の768次元 vector（ruri-v3）。日本語訳・英語原文どちらにも embedding 付与。"

columns:
  - name: memories.source
    description: "配信元の識別子。LIKE パターンで絞込み。"
    hints:
      enum_values:
        - "aws/blogs/news"
        - "aws/blogs/news/original"
        - "aws/classmethod"
        - "gcp/blogs/products"
        - "gcp/blogs/products/original"
        - "gcp/classmethod"
        - "gws/blogs/all"
        - "gws/blogs/all/original"
        - "gws/classmethod"
        - "gitlab/blogs/all"
        - "gitlab/blogs/all/original"
        - "gitlab/classmethod"
      note: |
        provider が常に最上位プレフィックス（aws/gcp/gws/gitlab）。
        日本語クエリ → 末尾 /original 抜き source 推奨（翻訳済み）。
        厳密英語確認 → /original 付きを参照。
        classmethod は日本語原文で /original suffix 無し。
        WHERE source LIKE 'aws/%' で AWS 関連（公式 + classmethod + 原文）を網羅。

clarification_fields:
  - name: cloud_provider
    description: "対象クラウド/サービス（AWS / GCP / GoogleWorkspace / GitLab / 全部）"
    attrs:
      type: string
      required: true
      order: 1
      keywords:
        AWS: "aws/%"
        aws: "aws/%"
        Amazon: "aws/%"
        GCP: "gcp/%"
        gcp: "gcp/%"
        "Google Cloud": "gcp/%"
        Workspace: "gws/%"
        gws: "gws/%"
        GitLab: "gitlab/%"
        gitlab: "gitlab/%"
        all: "%"
      enum_values: ["aws/%", "gcp/%", "gws/%", "gitlab/%", "%"]

  - name: include_classmethod
    description: "classmethod.jp の解説記事も含めるか"
    attrs:
      type: boolean
      required: false
      order: 2
      default: false

  - name: language
    description: "日本語訳のみ / 英語原文のみ / 両方"
    attrs:
      type: string
      required: false
      order: 3
      default: "ja"
      enum_values: ["ja", "en", "both"]

  - name: from_date
    attrs: { type: date, required: true, order: 4 }
  - name: to_date
    attrs: { type: date, required: true, order: 5 }
  - name: limit
    attrs: { type: integer, required: true, order: 6, default: 20 }

recipes:
  - name: recent_articles_by_provider
    label: "プロバイダ別期間指定 blog 記事（言語・classmethod 含有を制御）"
    description: |
      cloud_provider は LIKE パターン（aws/% / gcp/% / gws/% / gitlab/% / %）。
      include_classmethod=true なら aws/classmethod 等の解説記事も含む。
      language で日本語訳のみ（ja）/ 英語原文のみ（en）/ 両方（both）を切替。
    sql: |
      SELECT content, source, created_at
        FROM memories
       WHERE source LIKE :cloud_provider
         AND (:include_classmethod = 1 OR source NOT LIKE '%/classmethod')
         AND ( :language = 'both'
              OR (:language = 'ja' AND source NOT LIKE '%/original')
              OR (:language = 'en' AND source LIKE '%/original') )
         AND created_at BETWEEN :from_date AND :to_date
       ORDER BY created_at DESC
       LIMIT :limit
```

### 5.3 責任境界（ruby-knowledge-db 踏襲）

このrepo の責務:
- `cloud_knowledge.db` の生成・更新
- ruby-knowledge-store の migration 適用（`003_extend_meta.sql` の hints_json/recipe_sql/recipe_label 列含む）

このrepo の非責務:
- recipe / clarification_field データ → dotfiles `chiebukuro-mcp/scripts/meta_patches/cloud_knowledge.yml` に置く

---

## 6. エラー処理・運用ガード

### 6.1 ホストガード（ruby-knowledge-db 同型）

書き込み系タスク（`rake daily` / `rake fetch:*` / `rake translate:*` / `rake import:*` / `rake esa:*`）は `config/environments/production.yml` の `allowed_write_host` と `scutil --get LocalHostName` 一致チェック。

```yaml
# config/environments/production.yml
allowed_write_host: MacBook-Air-M3
```

`ALLOW_WRITE=1` で escape hatch。

### 6.2 Phase 別エラー処理方針

| Phase | 失敗時 | リトライ性 |
|---|---|---|
| fetch | RSS 取得失敗 → 該当 source abort して phase 終了 | 区間同じで DIR 新規作成して再実行で復元可能 |
| translate | Haiku API 失敗 → 当該 MD だけ fail-fast、他は skip 続行 | tmpdir の未翻訳 MD だけ再実行可能 |
| import | content_hash UNIQUE 違反 → 自動 skip | 安全に再実行可 |
| esa | API 失敗 → 当該記事 fail、Phase 2b は partial complete（`last_completed_*` 書かない） | WIP 検出 → next run で拾い直し |

### 6.3 翻訳プロンプト設計（CLAUDE.md コンタミ回避）

```ruby
# lib/cloud_knowledge_db/translator.rb
class Translator
  SYSTEM_PROMPT = <<~EN
    You are a precise English-to-Japanese translator for cloud platform technical blog articles.
    Translate the provided article to natural Japanese suitable for engineers.
    Rules:
      - Preserve all code blocks, URLs, product names, and technical terms verbatim.
      - Use formal-but-casual technical style (です/ます). Do NOT use slang or dialects.
      - Output ONLY the translation. Do not add explanations or meta commentary.
  EN

  def translate(article_md)
    client.messages.create(
      model: model_resolver.resolve(:haiku),
      system: [{ type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } }],
      messages: [{ role: "user", content: article_md }],
      max_tokens: 4096
    )
  end
end
```

ポイント:
- `system` は英語固定（`~/CLAUDE.md` の口調指示が混ざらない）
- `cache_control` で system prompt を prompt cache 対象に → 連続翻訳で TTFT 短縮
- 「方言禁止」を system prompt に明記 → 出力にギャル口調が出る事故を二重に防ぐ
- `ANTHROPIC_API_KEY` は macOS Keychain から取得（`security find-generic-password -s anthropic-api-key -w`）

### 6.4 汚染検知タスク

| タスク | 内容 |
|---|---|
| `rake db:scan_pollution` | 既知の空メタマーカー（"翻訳できません" "出力フォーマット" "空" 等）+ 重複候補（source, 先頭200文字）検出 |
| `rake db:scan_contamination` | CLAUDE.md コンタミ専用。「ピョン」「チェケラッチョ」「じゃりんこ」「ウチ」「あんさん」「質問？」「了解。」等の混入検知 |
| `rake db:delete_polluted IDS=...` | 明示 ID 指定で破壊削除、host guard 有効 |
| `rake esa:find_duplicates [DATE=...]` | 同名/同カテゴリ重複検出 |
| `rake esa:delete IDS=...` | esa 記事削除、host guard 有効 |
| `rake smoke:rss_endpoints` | 各 RSS/ATOM endpoint の HEAD 死活確認（CI 除外、smoke 用） |

---

## 7. Token 有効活用戦略（モデル選択）

### 7.1 原則

```
Haiku  → 大量 + 定型 + 失敗してもリトライ可能（翻訳・分類）
Sonnet → ほぼ全部の「普通」のタスク（オーケストレータ、レポート）
Opus   → 「大事ポイント」と「判断」（esa 本文生成、削除triage、main session）
```

### 7.2 Ruby Anthropic SDK 直叩きの割り当て

| 用途 | クラス | 短名 |
|---|---|---|
| 英→日翻訳 | `Translator` | haiku |
| 記事タグ分類 | `ContentClassifier` | haiku |
| デイリー要約記事生成 | `DailySummarizer` | opus |
| その他要約・整形 | （新規必要時） | sonnet（default） |

### 7.3 Claude Code subagent の割り当て

| subagent | 短名 | 役割 |
|---|---|---|
| `cloud-knowledge-db-daily` | sonnet | PLAN/EXECUTE オーケストレータ |
| `cloud-knowledge-db-pollution-triage` | opus | 削除判断は事故ったら戻せない |
| `cloud-knowledge-db-source-health` | sonnet | RSS 死活＋ adapter 昇格レポート（週次想定） |

### 7.4 Runtime Model Resolver（リビジョンアップ作業ゼロ）

```ruby
# lib/cloud_knowledge_db/model_resolver.rb
class ModelResolver
  FAMILIES = %w[haiku sonnet opus].freeze

  def initialize(client: Anthropic::Client.new)
    @client = client
    @cache = {}
  end

  # @param family [String, Symbol] "haiku" / "sonnet" / "opus"
  # @return [String] 実モデルID（family 内最新）
  def resolve(family)
    family = family.to_s
    raise ArgumentError, "unknown family: #{family}" unless FAMILIES.include?(family)

    if (pin = ENV["CLOUD_KB_PIN_#{family.upcase}"])
      return pin
    end

    @cache[family] ||= fetch_latest(family)
  end

  private

  def fetch_latest(family)
    models = @client.models.list  # GET /v1/models
    candidates = models.data.select { |m| m.id.start_with?("claude-#{family}-") }
    raise "no model for family: #{family}" if candidates.empty?
    candidates.max_by { |m| version_tuple(m.id) }.id
  end

  def version_tuple(id)
    id.scan(/\d+/).map(&:to_i)
  end
end
```

### 7.5 config（短名のみ、実IDは runtime resolve）

```yaml
# config/environments/production.yml
models:
  translator:       haiku
  classifier:       haiku
  daily_summarizer: opus
  default:          sonnet
```

`model_aliases` は持たない。Anthropic が新版リリースしても config 変更不要。

### 7.6 起動時ログ + bookmark 記録

```
[ModelResolver] resolved haiku  -> claude-haiku-4-5-20251001
[ModelResolver] resolved sonnet -> claude-sonnet-4-6
[ModelResolver] resolved opus   -> claude-opus-4-6
```

`db/last_run.yml` の各 phase entry に `models_used` を記録（4.5 参照）。

### 7.7 Escape Hatch

- `CLOUD_KB_PIN_HAIKU=claude-haiku-4-5-20251001` 等で env var から pin 可能
- テスト再現性、本番不調時の rollback、A/B テスト用

### 7.8 dev/test のコスト削減

```yaml
# config/environments/test.yml
models:
  translator:       haiku
  classifier:       haiku
  daily_summarizer: haiku   # production は opus、test は haiku に明示降格
  default:          haiku
```

短名指定なので env ごとに自由に上書き可能。

---

## 8. ローカル subagent / スラッシュコマンド設計

### 8.1 配置（プロジェクトプライベート）

```
cloud-knowledge-db/.claude/
├── agents/
│   ├── cloud-knowledge-db-daily.md
│   ├── cloud-knowledge-db-pollution-triage.md
│   └── cloud-knowledge-db-source-health.md
├── commands/
│   └── cloud-knowledge-db-daily.md
└── settings.local.json
```

- `~/.claude/` には**置かない**（ユーザー全体に漏れない）
- `~/.claude/skills/` 配下の skill も作らない（user-wide 汚染防止）

### 8.2 起動フロー（PLAN/CONFIRMED/EXECUTE）

```
ユーザー: /cloud-knowledge-db-daily
  ↓
commands/cloud-knowledge-db-daily.md → subagent dispatch
  ↓
agents/cloud-knowledge-db-daily.md (PLANモード)
  ↓ PLAN出力（FLOOR/WIP/推定件数 + CONFIRMEDトークン）
ユーザー: CONFIRMED SINCE=... BEFORE=... を含めて再 dispatch
  ↓
agents/cloud-knowledge-db-daily.md (EXECUTEモード)
  ↓ rake daily + scan_pollution + scan_contamination + esa:find_duplicates
完了レポート
```

### 8.3 PLAN モード仕様

```
入力: 引数なし
処理:
  1. db/last_run.yml を読み、各 *_blog source ごとに：
     - last_completed_before 取得 (なければ "epoch" 扱い)
     - WIP判定 (last_started_before > last_completed_before)
  2. FLOOR = min(last_completed_before)
  3. 推奨 SINCE/BEFORE 算出 (FLOOR ~ 今日)
  4. 直近24h想定で fetch の dry-run（HEAD で URL生存確認のみ）
  5. レポート出力:
     - 各source: bookmark状態、WIP有無、推定取得件数
     - 推奨 CONFIRMED トークン: "CONFIRMED SINCE=YYYY-MM-DD BEFORE=YYYY-MM-DD"
```

### 8.4 EXECUTE モード仕様

```
入力: CONFIRMED SINCE=... BEFORE=... トークン
処理:
  1. APP_ENV=production rake daily SINCE=... BEFORE=...
  2. 完了後 rake db:scan_pollution
  3. 完了後 rake db:scan_contamination
  4. 完了後 rake esa:find_duplicates DATE=...
  5. 結果レポート（処理件数、WIP残、汚染検出）
```

### 8.5 settings.local.json で必要な permissions

```json
{
  "permissions": {
    "allow": [
      "Bash(bundle exec rake daily:*)",
      "Bash(bundle exec rake fetch:*)",
      "Bash(bundle exec rake translate:*)",
      "Bash(bundle exec rake import:*)",
      "Bash(bundle exec rake esa:*)",
      "Bash(bundle exec rake db:scan_pollution)",
      "Bash(bundle exec rake db:scan_contamination)",
      "Bash(bundle exec rake esa:find_duplicates*)",
      "Bash(scutil --get LocalHostName)"
    ]
  }
}
```

### 8.6 subagent frontmatter 例

```yaml
---
name: cloud-knowledge-db-daily
description: Daily ingestion orchestrator. Loads bookmark, runs PLAN, gates on CONFIRMED token, executes rake daily, runs post-checks.
model: sonnet
tools: Bash, Read
---
```

```yaml
---
name: cloud-knowledge-db-pollution-triage
description: Analyzes scan_pollution / scan_contamination output and recommends DELETE IDs. Conservative — Opus for judgment.
model: opus
tools: Bash, Read
---
```

```yaml
---
name: cloud-knowledge-db-source-health
description: Checks RSS/ATOM endpoint health and recommends adapter upgrades (RSS → WebFetch → Chrome). Weekly cadence.
model: sonnet
tools: Bash, Read, WebFetch
---
```

---

## 9. テスト戦略（t-wada style TDD、test-unit）

### 9.1 各 repo 独立テスト

```bash
# cloud-knowledge-db
bundle exec rake test

# cloud-blog-collector
cd ../cloud-blog-collector && bundle exec rake test
```

### 9.2 テスト分類

| 種別 | 対象 | 実モデル/実API |
|---|---|---|
| unit | adapter parser, slug 生成, ModelResolver, TrunkBookmark | 使わない（fixture XML/JSON、stub クライアント） |
| integration | rake fetch:* / translate:* / import:* / esa:* phase 連携 | 使わない（FakeAnthropicClient, FakeEsaClient, fixture RSS） |
| smoke | 実 API endpoint 死活（`rake smoke:rss_endpoints`） | 実 HTTP（GET HEAD のみ）、LLM 未使用、CI 除外 |

### 9.3 LLM 呼び出しテストの stub 方針

- `Translator` テスト: `FakeAnthropicClient`（決定論レスポンス返す）→ system prompt 検証＋出力フォーマット検証
- `DailySummarizer` テスト: 同上
- 実モデル叩くテストは禁止（コスト＋非決定論）

### 9.4 CLAUDE.md コンタミ専用テスト

```ruby
# test/test_contamination.rb
class ContaminationTest < Test::Unit::TestCase
  CONTAMINATION_MARKERS = %w[ピョン チェケラッチョ じゃりんこ ウチ あんさん 質問？ 確認？ 了解。].freeze

  def test_translator_system_prompt_is_clean
    prompt = CloudKnowledgeDb::Translator::SYSTEM_PROMPT
    CONTAMINATION_MARKERS.each do |m|
      assert_not_match(/#{m}/, prompt, "system prompt contains contamination marker: #{m}")
    end
  end

  def test_daily_summarizer_system_prompt_is_clean
    # 同上
  end
end
```

### 9.5 TDD フロー

- 各 collector adapter: fixture 配置 → テスト書いて red → 実装 → green → refactor
- 翻訳プロンプト: contamination marker テストが先、品質テスト後。red→green
- bookmark twin-commit: state 遷移を 1 ケース 1 テストで網羅

---

## 10. ファイル構成（最終形）

### 10.1 cloud-knowledge-db/

```
cloud-knowledge-db/
├── .ruby-version                4.0.1
├── .gitignore
├── .mcp.json                    chrome-mcp 等の参照
├── .claude/
│   ├── agents/
│   │   ├── cloud-knowledge-db-daily.md
│   │   ├── cloud-knowledge-db-pollution-triage.md
│   │   └── cloud-knowledge-db-source-health.md
│   ├── commands/
│   │   └── cloud-knowledge-db-daily.md
│   └── settings.local.json
├── CLAUDE.md
├── README.md
├── Gemfile / Gemfile.lock
├── Rakefile
├── config/
│   ├── sources.yml
│   ├── chiebukuro.json.example
│   └── environments/
│       ├── development.yml
│       ├── test.yml
│       └── production.yml
├── lib/cloud_knowledge_db/
│   ├── orchestrator.rb
│   ├── translator.rb
│   ├── daily_summarizer.rb
│   ├── content_classifier.rb
│   ├── esa_writer.rb
│   ├── trunk_bookmark.rb
│   ├── host_guard.rb
│   ├── model_resolver.rb
│   └── config.rb
├── scripts/
│   ├── update_all.rb
│   └── seed_meta.rb
├── docs/superpowers/specs/
│   └── 2026-04-16-cloud-knowledge-db-design.md
├── db/
│   └── last_run.yml
└── test/
    ├── test_helper.rb
    ├── test_translator.rb
    ├── test_daily_summarizer.rb
    ├── test_contamination.rb
    ├── test_trunk_bookmark.rb
    ├── test_model_resolver.rb
    └── test_orchestrator.rb
```

### 10.2 cloud-blog-collector/（gem）

```
cloud-blog-collector/
├── cloud_blog_collector.gemspec
├── lib/cloud_blog_collector/
│   ├── version.rb
│   ├── collector.rb
│   ├── source_registry.rb
│   └── adapters/
│       ├── rss.rb
│       ├── web_fetch.rb
│       ├── chrome.rb
│       └── classmethod.rb
└── test/
    ├── test_helper.rb
    ├── fixtures/
    │   ├── aws_rss_sample.xml
    │   ├── gcp_rss_sample.xml
    │   ├── gws_rss_sample.xml
    │   ├── gitlab_atom_sample.xml
    │   └── classmethod_rss_sample.xml
    ├── test_rss_adapter.rb
    ├── test_web_fetch_adapter.rb
    ├── test_chrome_adapter.rb
    └── test_classmethod_adapter.rb
```

### 10.3 dotfiles 追加

```
dotfiles/chiebukuro-mcp/chiebukuro-mcp/scripts/meta_patches/
└── cloud_knowledge.yml
```

---

## 11. APP_ENV / DB / esa 環境別マトリクス

| APP_ENV | DB ファイル | esa team | esa wip | esa category prefix |
|---|---|---|---|---|
| development（デフォルト） | `db/cloud_knowledge_development.db` | `bist` | true | `development/cloud-trunk-changes/` |
| test | `db/cloud_knowledge_test.db` | `bist` | true | `test/cloud-trunk-changes/` |
| production | `~/Library/.../chiebukuro-mcp/db/cloud_knowledge.db`（iCloud 同期） | `bash-trunk-changes` | false | `production/cloud-trunk-changes/` |

---

## 12. 確定した設計判断（Q&A サマリ）

| Q | 決定 |
|---|---|
| Q1: リポジトリ構造 | **B 軽分割**: orchestrator + cloud-blog-collector gem + ruby-knowledge-store 流用 |
| Q2: 言語戦略 | **A 英語一次 + Haiku 翻訳**: 英語が最新、両方DB格納 |
| Q3: esa デイリー形式 | **A ソース別記事**: ruby-knowledge-db 踏襲 |
| Q4: classmethod 扱い | **B DB格納のみ、esa 投稿対象外**: 補助コンテキスト |
| Q5: DB 配置 / APP_ENV | **A ruby-knowledge-db 同型**: iCloud 上分離、host guard 流用 |
| Q6: ローカル skill | **A subagent 同型**: PLAN/CONFIRMED/EXECUTE、project-private |
| Q7: 翻訳パイプライン | **B 4-phase**: fetch → translate → import → esa |
| 追加要件 | chiebukuro-mcp 連携: meta_patches で recipes / clarification_fields 定義 |
| 追加要件 | CLAUDE.md コンタミ回避: API 直叩き + system 英語固定 + コンタミテスト |
| 追加要件 | プロジェクト private subagent: `.claude/` 配下、`~/.claude/` 不使用 |
| 追加要件 | モデル割当: Haiku (translator/classifier)、Opus (summarizer/triage)、Sonnet default |
| 追加要件 | リビジョンアップ作業ゼロ: runtime resolve via `/v1/models` |

---

## 13. 実装フェーズ提案（writing-plans に渡す前の頭出し）

おおまかな build 順序の頭出し（詳細は writing-plans skill で実装計画化）：

1. **基盤**: cloud-knowledge-db の skeleton + ModelResolver + Config + HostGuard + TrunkBookmark（コピー流用）
2. **collector gem**: cloud-blog-collector skeleton + RssAdapter (AWS 1ソースで PoC) + fixture テスト
3. **翻訳パイプライン**: Translator (Haiku 直叩き) + コンタミテスト + fetch → translate phase
4. **永続化**: import phase（ruby-knowledge-store 流用）+ DB スキーマ動作確認
5. **esa**: esa_writer コピー + DailySummarizer (Opus) + esa phase
6. **オーケストレータ**: rake daily 統合 + 二段bookmark + scan_pollution / scan_contamination
7. **subagent**: 3 つの .claude/agents/ + commands + settings.local.json
8. **chiebukuro-mcp 連携**: meta_patches yaml + apply_meta_patches.rb 実行 + chiebukuro.json 追加
9. **残り 3 ソース展開**: GCP / GWS / GitLab adapter + sources.yml
10. **classmethod**: ClassmethodAdapter + ContentClassifier + esa スキップロジック
11. **source-health subagent + smoke task**: 週次運用整備
12. **README / CLAUDE.md / dotfiles 反映**

---

## 14. 関連リポジトリ（開発時クローン必要）

| リポジトリ | 役割 |
|---|---|
| bash0C7/cloud-knowledge-db（このrepo） | orchestrator |
| bash0C7/cloud-blog-collector（新規） | blog adapter |
| bash0C7/ruby-knowledge-store（既存） | Store / Embedder / Migrator |
| bash0C7/chiebukuro-mcp（既存） | MCP サーバー本体 |
| dotfiles/chiebukuro-mcp/scripts/meta_patches/cloud_knowledge.yml（新規） | meta データ |

---

以上。
