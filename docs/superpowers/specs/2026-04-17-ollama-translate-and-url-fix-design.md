# Ollama 翻訳切替 + 記事URL正規化 + 見出しリンク化

作成日: 2026-04-17

## 背景

- `bash-trunk-changes` esa post #118 で、記事リンクが Blogger コメントフィード URL (`http://workspaceupdates.googleblog.com/feeds/.../comments/default`) になっている事実を確認した。
- feedburner 経由の Atom 配信では `rss.rb#extract_url` が `rel="alternate" type="text/html"` を厳密に選べておらず、また feedburner 独自拡張 `<feedburner:origLink>` を参照していない。
- 現行 `Translator` は `claude` CLI を呼んで翻訳しており、記事量に比例して Anthropic API トークンを消費している。翻訳品質と速度は許容範囲だが、コスト観点でローカル LLM (`ollama run gemma4`) に置き換えたい。
- esa の日次まとめ記事では、リンクが本文末尾に「記事リンク」として単独行で付いているが、見出し全体を直接リンクにしたほうがクリック動線が自然である。

## ゴール

1. これ以降 fetch する RSS/Atom 記事の URL が、必ず人間が読む HTML 記事 URL になること。
2. Daily summarizer が出力する esa 記事の各セクション見出しが、タイトル全体を URL にリンクする Markdown 形式になること。
3. `Translator` が `claude` CLI の代わりに `ollama run gemma4` を呼び、Anthropic トークンを消費しないこと。
4. ollama 未起動時は pipeline 開始直後に明確にエラー終了すること。

## 非ゴール

- 既存 DB レコード (`memories.content` 内の YAML frontmatter `url`) の遡及修正は行わない。
- 既に esa に投稿済みの記事の書き換えは行わない。
- `ContentClassifier` / `DailySummarizer` の LLM 切替は行わない (引き続き `claude` CLI)。
- 既存の翻訳キャッシュ (`translation_cache`) エントリは保持する。

## 変更内容

### A. RSS adapter: URL 正規化 (`cloud-blog-collector`)

対象: `lib/cloud_blog_collector/adapters/rss.rb#extract_url`

優先順位:

1. `<feedburner:origLink>` が存在しその値が非空なら採用 (feedburner が記事 HTML URL を保存している)。
2. `rel="alternate"` かつ `type="text/html"` の link を採用。
3. `rel="alternate"` (type 不問) の link を採用。
4. 上記いずれにも合致しない場合 `it.link.href` / `it.link.to_s` に fallback。

実装ポイント:

- Atom `<feedburner:origLink>` は `rss` gem では `feedburner_origLink` メソッドとして露出する。`respond_to?` で防御する。
- link 選択のルールは `extract_url` 内のみで閉じさせる (他メソッドの責務に影響させない)。
- 既存の「`rel='replies'` が先に来る feedburner feed への対策」コメントは更新する。

テスト: `cloud-blog-collector` の RSS adapter 向けテストに fixture を追加する。

- fixture 1: feedburner Atom で `<feedburner:origLink>` 付きのもの → `origLink` を採用すること。
- fixture 2: 通常の Atom で `rel="alternate" type="text/html"` が複数 link の中にあるもの → 正しい HTML URL を採用すること。
- fixture 3: `link` 単独の RSS 2.0 → 従来通り `it.link.to_s` を採用すること。

### B. Daily summarizer: 見出しリンク化 (`cloud-knowledge-db`)

対象: `lib/cloud_knowledge_db/daily_summarizer.rb#SYSTEM_PROMPT`

プロンプト差分 (意図のみ記述、最終的な文言は実装時に整える):

- 旧: `各記事は「## <タイトル>」の見出し配下に、要点3つ以内の箇条書き、最後にリンクを付ける。`
- 新: `各記事は「## [<タイトル>](<URL>)」形式で見出し全体をリンクにし、その配下に要点3つ以内の箇条書きを置く。末尾に単独のリンク行を出力してはならない。`

テスト: `test/test_daily_summarizer.rb` を更新し、生成された markdown に対して以下を検証する。

- `## [` で始まる見出しが記事数分存在すること。
- `[記事リンク]` や末尾 bare URL 行が含まれないこと。

`FakeClaudeRunner` (または既存の stub 相当) の戻り値を新形式に書き換える。

### C. Translator: Ollama gemma4 切替 (`cloud-knowledge-db`)

新規ファイル: `lib/cloud_knowledge_db/ollama_runner.rb`

- `initialize(model:)` で ollama モデル名 (既定 `gemma4`) を受け取る。
- `execute(prompt)` で `Open3.popen3("ollama", "run", @model)` を起動し、stdin にプロンプトを流し込む。
- stdout を読み切って `.strip` を返す。stderr はログに書かない (現行 `ClaudeRunner` と揃える)。
- chdir は不要。ollama CLI は `~/CLAUDE.md` を読まないため。
- timeout は設けない (現行 `ClaudeRunner` と揃える)。将来必要になったら別途。

`Translator` 変更:

- `require_relative 'claude_runner'` を `require_relative 'ollama_runner'` に差し替え。
- `initialize(model: 'gemma4')` とし、`OllamaRunner.new(model: model)` を保持。
- `SYSTEM_PROMPT` は現行維持 (英日翻訳、コード/URL/固有名詞保持、です・ます、slang 禁止)。

テスト: `test/test_translator.rb` を `FakeOllamaRunner` 差替え方式に変更する。

- 既存の stub 注入パターンを `FakeClaudeRunner` → `FakeOllamaRunner` に差し替え。
- 翻訳結果の中身比較テストは「runner に渡されたプロンプトに system prompt と記事本文が含まれる」ことの確認に留める (現行テストの方針と同じ)。

### D. Ollama 可用性チェック (fail-fast)

対象: pipeline のエントリポイント (`Rakefile` の `daily` タスク、および `translate:*` タスクの先頭)

実装方針:

- `lib/cloud_knowledge_db/ollama_runner.rb` に class method `OllamaRunner.ensure_available!` を置く。
- 実装: `Open3.capture2("ollama", "list")` の exit status を確認。非ゼロ or コマンド不在の `Errno::ENOENT` なら `RuntimeError` で即座に失敗。
- メッセージ例: `ollama is not available: install and start 'ollama serve' before running this task`.
- `Rakefile` の以下タスク先頭で `OllamaRunner.ensure_available!` を呼ぶ:
  - `daily`
  - `translate:*` (全 provider 分)

`import:*` / `esa:*` / `fetch:*` は翻訳を走らせないので呼ばない。

テスト: `test/test_ollama_runner.rb`

- ollama コマンドが PATH に存在する CI/ローカルでは `ensure_available!` が例外を投げないこと。
- `PATH=""` の subprocess 経由で `ensure_available!` が `RuntimeError` を投げること。
  (ollama 未インストール環境の再現。`Open3.capture2` が `Errno::ENOENT` を投げる経路のテスト。)

### E. 翻訳キャッシュ: 既存エントリ保持

`lib/cloud_knowledge_db/translation_cache.rb` に変更を加えない。

- cache key が model 非依存ならば、Claude 時代に作った訳は gemma4 切替後もヒットする。
- 本仕様では「既存キャッシュ保持」を守ればよく、無効化や TTL 設定は行わない。
- 実装前に `translation_cache.rb` のキー設計を確認し、本前提が成立することを確認する。もし key に model が含まれていた場合は、本 spec のスコープを超える議題として user に報告する。

## アーキテクチャ影響範囲

```
cloud-blog-collector/
  lib/cloud_blog_collector/adapters/rss.rb   ← A. extract_url 強化
  test/...                                    ← A. fixture テスト追加

cloud-knowledge-db/
  lib/cloud_knowledge_db/ollama_runner.rb     ← C/D. 新規
  lib/cloud_knowledge_db/translator.rb        ← C. ClaudeRunner → OllamaRunner
  lib/cloud_knowledge_db/daily_summarizer.rb  ← B. プロンプト変更
  Rakefile                                    ← D. daily/translate 先頭で ensure_available!
  test/test_ollama_runner.rb                  ← D. 新規
  test/test_translator.rb                     ← C. FakeOllamaRunner 差替え
  test/test_daily_summarizer.rb               ← B. 期待 markdown 更新
  test/support/                                ← C. FakeOllamaRunner 追加
```

## テスト戦略

- 実 LLM を呼ばない (既存方針踏襲)。Fake runner で差し替える。
- repo 全体の回帰は `bundle exec rake test` で一括確認する (user 指示の全量テスト原則)。
- RSS fixture は minimal な XML 断片を使い、外部 HTTP を打たない。

## ロールアウト

1. `cloud-blog-collector` 側で A を PR 相当の単位で実装し、test グリーン後マージ。
2. `cloud-knowledge-db` 側で C → D → B の順に実装。`bundle exec rake test` 全 green を毎ステップ確認。
3. `APP_ENV=test` で小スコープ (単一 source, 1 日分) の `daily` を smoke 実行し、esa 側の見た目と URL を確認。
4. 本番反映は user 判断 (host guard 既存)。

## リスクと緩和

- ollama `gemma4:latest` (e4b, 9.6GB) の翻訳品質が Haiku より劣る可能性。
  - 緩和: 初回 smoke 実行時に user が目視確認し、問題があれば `model:` を `gemma4:e2b` など別 variant に切替する escape hatch を残す (`Translator.new(model: ...)` の引数に既に対応済み)。
- ollama プロセスの停止・クラッシュ時に pipeline が無言で止まるリスク。
  - 緩和: D で pipeline 先頭 fail-fast を実装する。翻訳中の個別呼び出し失敗時は現行通り例外として伝播する。
- `feedburner:origLink` が Atom feed に含まれないケースでの regression。
  - 緩和: 優先順位 2 / 3 / 4 の fallback を残し、既存 RSS 2.0 feed への影響をゼロにする。
