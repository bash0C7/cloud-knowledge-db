# Ollama 翻訳切替 + 記事URL正規化 + 見出しリンク化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Claude CLI translator with local `ollama run gemma4`, normalize RSS/Atom article URLs to human-readable HTML pages (feedburner-aware), and emit daily-summary esa posts with headings that are themselves links.

**Architecture:** Three focused changes across two repos. In `cloud-blog-collector`, strengthen `Adapters::Rss#extract_url` to prefer `<feedburner:origLink>` and `rel="alternate" type="text/html"`. In `cloud-knowledge-db`, introduce `OllamaRunner` (Open3-based, stdin prompt) and swap it into `Translator`, add a pipeline fail-fast availability check, and revise `DailySummarizer` system prompt to emit `## [Title](URL)` headings with no trailing "記事リンク" line.

**Tech Stack:** Ruby 4.0 (CRuby), `rss` gem, `Open3`, test-unit xUnit style (t-wada TDD), rake.

---

## File Structure

### cloud-blog-collector

| Path | Action | Responsibility |
|---|---|---|
| `lib/cloud_blog_collector/adapters/rss.rb` | Modify | Add `<feedburner:origLink>` preference and `type="text/html"` preference to `extract_url` |
| `test/fixtures/feedburner_atom_sample.xml` | Create | Feedburner-wrapped Blogger Atom entry with `<feedburner:origLink>` and `rel="replies"` first link |
| `test/fixtures/multi_link_atom_sample.xml` | Create | Atom entry with several `<link>` elements where `rel="alternate" type="text/html"` is not first |
| `test/test_rss_adapter.rb` | Modify | Add tests for feedburner precedence and type=text/html precedence |

### cloud-knowledge-db

| Path | Action | Responsibility |
|---|---|---|
| `lib/cloud_knowledge_db/ollama_runner.rb` | Create | `Open3`-based wrapper around `ollama run <model>` + `.ensure_available!` class method |
| `lib/cloud_knowledge_db/translator.rb` | Modify | Use `OllamaRunner` instead of `ClaudeRunner`; default `model: 'gemma4'` |
| `lib/cloud_knowledge_db/daily_summarizer.rb` | Modify | Update `SYSTEM_PROMPT` to `## [Title](URL)` heading-link format |
| `Rakefile` | Modify | Call `OllamaRunner.ensure_available!` at start of `daily` and inside `do_translate` |
| `test/test_ollama_runner.rb` | Create | Unit tests for `ensure_available!` success and `Errno::ENOENT` failure paths |
| `test/test_translator.rb` | Modify | Keep using `FakeRunner` for `@runner`; only update model-default assertion |
| `test/test_daily_summarizer.rb` | Modify | Stub-return a markdown sample in the new heading-link format; assert `## [` pattern and absence of `[記事リンク]` |

---

## Task 1: Strengthen RSS adapter URL selection (cloud-blog-collector)

**Repo:** `~/dev/src/github.com/bash0C7/cloud-blog-collector`

**Files:**
- Modify: `lib/cloud_blog_collector/adapters/rss.rb` (method `extract_url`)
- Create: `test/fixtures/feedburner_atom_sample.xml`
- Create: `test/fixtures/multi_link_atom_sample.xml`
- Modify: `test/test_rss_adapter.rb`

- [ ] **Step 1.1: Create feedburner fixture**

Create `test/fixtures/feedburner_atom_sample.xml`:

```xml
<?xml version='1.0' encoding='UTF-8'?>
<feed xmlns='http://www.w3.org/2005/Atom'
      xmlns:feedburner='http://rssnamespace.org/feedburner/ext/1.0'>
  <title>GoogleAppsUpdates (feedburner)</title>
  <updated>2026-04-16T12:00:00Z</updated>
  <id>tag:example.com,2026:feedburner</id>
  <entry>
    <id>tag:example.com,2026:feedburner-post-1</id>
    <title>New GWS Feature</title>
    <link rel='replies' type='application/atom+xml'
          href='http://workspaceupdates.googleblog.com/feeds/7306522852233198999/comments/default'/>
    <link rel='replies' type='text/html'
          href='http://workspaceupdates.googleblog.com/2026/04/new-gws.html#comment-form'/>
    <link rel='edit' type='application/atom+xml'
          href='https://www.blogger.com/feeds/edit'/>
    <link rel='self' type='application/atom+xml'
          href='http://workspaceupdates.googleblog.com/feeds/default/posts/123'/>
    <link rel='alternate' type='text/html'
          href='http://feedproxy.google.com/~r/GoogleAppsUpdates/~3/xyz/new-gws.html'/>
    <published>2026-04-16T10:00:00Z</published>
    <updated>2026-04-16T10:05:00Z</updated>
    <content type='html'>&lt;p&gt;Body of new GWS post.&lt;/p&gt;</content>
    <feedburner:origLink>http://workspaceupdates.googleblog.com/2026/04/new-gws.html</feedburner:origLink>
  </entry>
</feed>
```

- [ ] **Step 1.2: Create multi-link atom fixture (no feedburner, alternate not first)**

Create `test/fixtures/multi_link_atom_sample.xml`:

```xml
<?xml version='1.0' encoding='UTF-8'?>
<feed xmlns='http://www.w3.org/2005/Atom'>
  <title>Multi-link Atom</title>
  <updated>2026-04-16T12:00:00Z</updated>
  <id>tag:example.com,2026:multilink</id>
  <entry>
    <id>tag:example.com,2026:multilink-1</id>
    <title>Article With Many Links</title>
    <link rel='self' type='application/atom+xml'
          href='https://example.com/feeds/default/posts/555'/>
    <link rel='edit' type='application/atom+xml'
          href='https://example.com/feeds/edit/555'/>
    <link rel='alternate' type='text/html'
          href='https://example.com/posts/many-links'/>
    <published>2026-04-16T10:00:00Z</published>
    <updated>2026-04-16T10:05:00Z</updated>
    <content type='html'>&lt;p&gt;Multi link body.&lt;/p&gt;</content>
  </entry>
</feed>
```

- [ ] **Step 1.3: Write failing tests in test/test_rss_adapter.rb**

Append these tests to `test/test_rss_adapter.rb` (inside the existing `class RssAdapterTest`):

```ruby
def test_fetch_prefers_feedburner_origlink_over_rel_alternate
  fb = File.expand_path('fixtures/feedburner_atom_sample.xml', __dir__)
  cfg = {
    'feed_url'        => "file://#{fb}",
    'source_article'  => 'gws/blogs/all',
    'source_original' => 'gws/blogs/all/original'
  }
  adapter = CloudBlogCollector::Adapters::Rss.new(cfg)
  out = adapter.fetch(since: Time.parse('2026-04-10'), before: Time.parse('2026-04-20'))
  assert_equal 1, out.length
  assert_equal 'http://workspaceupdates.googleblog.com/2026/04/new-gws.html', out.first[:url],
               'feedburner:origLink must take priority so we land on the real blog HTML URL'
end

def test_fetch_picks_rel_alternate_text_html_when_not_first_link
  ml = File.expand_path('fixtures/multi_link_atom_sample.xml', __dir__)
  cfg = {
    'feed_url'        => "file://#{ml}",
    'source_article'  => 'x/blogs/any',
    'source_original' => 'x/blogs/any/original'
  }
  adapter = CloudBlogCollector::Adapters::Rss.new(cfg)
  out = adapter.fetch(since: Time.parse('2026-04-10'), before: Time.parse('2026-04-20'))
  assert_equal 1, out.length
  assert_equal 'https://example.com/posts/many-links', out.first[:url]
end
```

- [ ] **Step 1.4: Run tests to see them fail**

Run:
```bash
cd ~/dev/src/github.com/bash0C7/cloud-blog-collector
bundle exec rake test TEST=test/test_rss_adapter.rb
```

Expected: `test_fetch_prefers_feedburner_origlink_over_rel_alternate` FAILS (existing code ignores `feedburner:origLink`, returns the `feedproxy.google.com` URL instead of the blog HTML URL).
The multi-link test may already pass; that's fine — the feedburner test must FAIL.

- [ ] **Step 1.5: Implement extract_url preference order**

Edit `lib/cloud_blog_collector/adapters/rss.rb`. Replace the existing `extract_url` method with:

```ruby
      # Priority: feedburner:origLink  >  rel="alternate" type="text/html"
      #         > rel="alternate"      >  it.link.* fallback.
      # feedburner-wrapped Blogger feeds return the proxy URL in rel=alternate;
      # <feedburner:origLink> carries the real article HTML URL.
      def extract_url(it)
        if it.respond_to?(:feedburner_origLink)
          orig = it.feedburner_origLink
          val  = orig.respond_to?(:content) ? orig.content : orig
          return val.to_s if val && !val.to_s.empty?
        end

        if it.respond_to?(:links) && it.links.respond_to?(:each)
          html_alt = it.links.find do |l|
            l.respond_to?(:rel) && l.rel.to_s == 'alternate' &&
              l.respond_to?(:type) && l.type.to_s == 'text/html'
          end
          return html_alt.href if html_alt && html_alt.respond_to?(:href) && html_alt.href

          alt = it.links.find { |l| l.respond_to?(:rel) && l.rel.to_s == 'alternate' }
          return alt.href if alt && alt.respond_to?(:href) && alt.href
        end

        return it.link.href if it.respond_to?(:link) && it.link.respond_to?(:href)
        it.link.to_s
      end
```

- [ ] **Step 1.6: Run rss adapter tests to verify green**

Run:
```bash
cd ~/dev/src/github.com/bash0C7/cloud-blog-collector
bundle exec rake test TEST=test/test_rss_adapter.rb
```

Expected: all rss adapter tests PASS (including the two new ones).

- [ ] **Step 1.7: Run the full collector test suite**

Run:
```bash
cd ~/dev/src/github.com/bash0C7/cloud-blog-collector
bundle exec rake test
```

Expected: all tests across the repo PASS.

- [ ] **Step 1.8: Commit**

```bash
cd ~/dev/src/github.com/bash0C7/cloud-blog-collector
git add lib/cloud_blog_collector/adapters/rss.rb \
        test/fixtures/feedburner_atom_sample.xml \
        test/fixtures/multi_link_atom_sample.xml \
        test/test_rss_adapter.rb
git commit -m "$(cat <<'EOF'
fix(rss): prefer feedburner:origLink and rel=alternate type=text/html

Feedburner-wrapped Blogger Atom feeds (e.g. GoogleAppsUpdates) expose
the blog HTML URL in <feedburner:origLink> while rel=alternate points
at a feedproxy redirect or — in degraded cases — the comments feed.
Prefer origLink, then rel=alternate type=text/html, then any alternate,
then the current fallback. This was surfaced by esa post #118 linking
to a Blogger comments feed URL.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Introduce OllamaRunner (cloud-knowledge-db)

**Repo:** `~/dev/src/github.com/bash0C7/cloud-knowledge-db`

**Files:**
- Create: `lib/cloud_knowledge_db/ollama_runner.rb`
- Create: `test/test_ollama_runner.rb`

- [ ] **Step 2.1: Write failing tests in test/test_ollama_runner.rb**

Create `test/test_ollama_runner.rb`:

```ruby
# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/ollama_runner'

class OllamaRunnerTest < Test::Unit::TestCase
  def test_initializes_with_model
    runner = CloudKnowledgeDb::OllamaRunner.new(model: 'gemma4')
    assert_equal 'gemma4', runner.instance_variable_get(:@model)
  end

  def test_ensure_available_raises_when_ollama_missing
    original_path = ENV['PATH']
    ENV['PATH'] = '/nonexistent-bin-path'
    assert_raise(RuntimeError) do
      CloudKnowledgeDb::OllamaRunner.ensure_available!
    end
  ensure
    ENV['PATH'] = original_path
  end

  def test_ensure_available_passes_when_ollama_present
    # This test only runs when ollama is actually installed locally.
    # If `which ollama` finds nothing, skip instead of failing.
    skip 'ollama not installed on this host' unless system('which ollama > /dev/null 2>&1')
    assert_nothing_raised do
      CloudKnowledgeDb::OllamaRunner.ensure_available!
    end
  end
end
```

- [ ] **Step 2.2: Run to see failure**

Run:
```bash
cd ~/dev/src/github.com/bash0C7/cloud-knowledge-db
bundle exec rake test TEST=test/test_ollama_runner.rb
```

Expected: FAIL with `LoadError` or `NameError: uninitialized constant CloudKnowledgeDb::OllamaRunner`.

- [ ] **Step 2.3: Implement OllamaRunner**

Create `lib/cloud_knowledge_db/ollama_runner.rb`:

```ruby
# frozen_string_literal: true
require 'open3'

module CloudKnowledgeDb
  class OllamaRunner
    def self.ensure_available!
      out, status = Open3.capture2('ollama', 'list')
      return if status.success?
      raise RuntimeError,
            "ollama is not available (ollama list exit #{status.exitstatus}): #{out.lines.first}"
    rescue Errno::ENOENT
      raise RuntimeError,
            "ollama is not available: install ollama and start 'ollama serve' before running this task"
    end

    def initialize(model:)
      @model = model
    end

    # @param prompt [String] full prompt text
    # @return [String] ollama output, stripped
    def execute(prompt)
      output = ''
      Open3.popen3('ollama', 'run', @model) do |stdin, stdout, stderr, wt|
        stdin.write(prompt)
        stdin.close
        t1 = Thread.new { output = stdout.read }
        stderr.read
        t1.join
        wt.value
      end
      output.strip
    end
  end
end
```

- [ ] **Step 2.4: Run to verify green**

Run:
```bash
cd ~/dev/src/github.com/bash0C7/cloud-knowledge-db
bundle exec rake test TEST=test/test_ollama_runner.rb
```

Expected: 3 tests PASS (`test_ensure_available_passes_when_ollama_present` passes because ollama is installed locally; it would skip on a machine without ollama).

- [ ] **Step 2.5: Commit**

```bash
cd ~/dev/src/github.com/bash0C7/cloud-knowledge-db
git add lib/cloud_knowledge_db/ollama_runner.rb test/test_ollama_runner.rb
git commit -m "$(cat <<'EOF'
feat(runner): add OllamaRunner for local-LLM translation

Wraps `ollama run <model>` via Open3 stdin/stdout, mirroring ClaudeRunner's
interface so it can be swapped in behind Translator. Exposes
OllamaRunner.ensure_available! for pipeline fail-fast when ollama is
not installed or the daemon is not running.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Swap Translator onto OllamaRunner

**Files:**
- Modify: `lib/cloud_knowledge_db/translator.rb`
- Modify: `test/test_translator.rb`

- [ ] **Step 3.1: Update test to require ollama_runner and change default model assertion**

Edit `test/test_translator.rb`. Replace the file with:

```ruby
# frozen_string_literal: true
require_relative 'test_helper'
require_relative 'support/fake_runner'
require 'cloud_knowledge_db/translator'

class TranslatorTest < Test::Unit::TestCase
  def setup
    @fake = FakeRunner.new('翻訳された日本語テキスト')
    @translator = CloudKnowledgeDb::Translator.new(model: 'gemma4')
    @translator.instance_variable_set(:@runner, @fake)
  end

  def test_translate_returns_text_from_runner
    out = @translator.translate('English article body.')
    assert_equal '翻訳された日本語テキスト', out
  end

  def test_prompt_includes_system_prompt_and_article
    @translator.translate('article body')
    assert_match(/English-to-Japanese translator/, @fake.last_prompt)
    assert_match(/article body/, @fake.last_prompt)
  end

  def test_default_model_is_gemma4
    t = CloudKnowledgeDb::Translator.new
    assert_equal 'gemma4', t.instance_variable_get(:@runner).instance_variable_get(:@model)
  end
end
```

- [ ] **Step 3.2: Run to see test failures**

Run:
```bash
cd ~/dev/src/github.com/bash0C7/cloud-knowledge-db
bundle exec rake test TEST=test/test_translator.rb
```

Expected: `test_default_model_is_gemma4` FAILS (current Translator defaults to `'haiku'` via `ClaudeRunner`).

- [ ] **Step 3.3: Swap Translator to OllamaRunner**

Edit `lib/cloud_knowledge_db/translator.rb`. Replace full file with:

```ruby
# frozen_string_literal: true
require_relative 'ollama_runner'

module CloudKnowledgeDb
  class Translator
    SYSTEM_PROMPT = <<~EN.freeze
      You are a precise English-to-Japanese translator for cloud platform technical blog articles.
      Translate the provided article to natural Japanese suitable for engineers.
      Rules:
        - Preserve all code blocks, URLs, product names, and technical terms verbatim.
        - Use formal-but-casual technical style (です/ます). Do NOT use slang, dialects, or playful endings.
        - Output ONLY the translation. Do not add explanations or meta commentary.
    EN

    def initialize(model: 'gemma4')
      @runner = OllamaRunner.new(model: model)
    end

    # @param article_md [String] English article
    # @return [String] Japanese translation
    def translate(article_md)
      prompt = "#{SYSTEM_PROMPT}\n\n---\n\n#{article_md}"
      @runner.execute(prompt)
    end
  end
end
```

- [ ] **Step 3.4: Run translator tests to verify green**

Run:
```bash
cd ~/dev/src/github.com/bash0C7/cloud-knowledge-db
bundle exec rake test TEST=test/test_translator.rb
```

Expected: all 3 tests PASS.

- [ ] **Step 3.5: Run full repo test suite**

Run:
```bash
cd ~/dev/src/github.com/bash0C7/cloud-knowledge-db
bundle exec rake test
```

Expected: all tests PASS (including contamination and cache tests — Translator's SYSTEM_PROMPT is unchanged).

- [ ] **Step 3.6: Commit**

```bash
cd ~/dev/src/github.com/bash0C7/cloud-knowledge-db
git add lib/cloud_knowledge_db/translator.rb test/test_translator.rb
git commit -m "$(cat <<'EOF'
feat(translator): run translation on local ollama gemma4

Switch Translator from ClaudeRunner (claude CLI, Haiku) to OllamaRunner
(ollama run gemma4) to eliminate per-article Anthropic token spend.
System prompt unchanged — English-only, slang-forbidden, so the
CLAUDE.md contamination guarantee and existing translation_cache entries
(cache is model-agnostic, keyed by basename) remain valid.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Rakefile fail-fast for ollama

**Files:**
- Modify: `Rakefile`

- [ ] **Step 4.1: Add require + calls to ensure_available!**

Edit `Rakefile`:

1. After line 4 (`require_relative 'lib/cloud_knowledge_db/trunk_bookmark'`), add:

```ruby
require_relative 'lib/cloud_knowledge_db/ollama_runner'
```

2. Inside `def do_translate(key, dir:)` (currently starts at `Rakefile:69`), add as the very first line inside the method body:

```ruby
  CloudKnowledgeDb::OllamaRunner.ensure_available!
```

Final method head should read:

```ruby
def do_translate(key, dir:)
  CloudKnowledgeDb::OllamaRunner.ensure_available!
  require 'bundler/setup'
  require_relative 'lib/cloud_knowledge_db/translator'
  require_relative 'lib/cloud_knowledge_db/translation_cache'
  ...
```

3. In the `task :daily do` block (currently at `Rakefile:402`), just after the existing `CloudKnowledgeDb::Config.ensure_write_host!` call, add:

```ruby
  CloudKnowledgeDb::OllamaRunner.ensure_available!
```

- [ ] **Step 4.2: Smoke-run help target to verify no load-time breakage**

Run:
```bash
cd ~/dev/src/github.com/bash0C7/cloud-knowledge-db
bundle exec rake -T | head -20
```

Expected: task list prints without exceptions; the `Rakefile` loads cleanly.

- [ ] **Step 4.3: Smoke-run full test suite**

Run:
```bash
cd ~/dev/src/github.com/bash0C7/cloud-knowledge-db
bundle exec rake test
```

Expected: all tests PASS. The Rake `test` task does not trigger `ensure_available!`, but we verify nothing regressed.

- [ ] **Step 4.4: Commit**

```bash
cd ~/dev/src/github.com/bash0C7/cloud-knowledge-db
git add Rakefile
git commit -m "$(cat <<'EOF'
feat(rake): fail fast when ollama is not available for translation

Call OllamaRunner.ensure_available! at the top of the daily pipeline
and at the entry of do_translate so a missing ollama daemon aborts
the run immediately instead of producing empty translations that
would pollute the cache and DB.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: DailySummarizer heading-link format

**Files:**
- Modify: `lib/cloud_knowledge_db/daily_summarizer.rb`
- Modify: `test/test_daily_summarizer.rb`

- [ ] **Step 5.1: Update daily summarizer tests**

Edit `test/test_daily_summarizer.rb`. Replace the file with:

```ruby
# frozen_string_literal: true
require_relative 'test_helper'
require_relative 'support/fake_runner'
require 'cloud_knowledge_db/daily_summarizer'

class DailySummarizerTest < Test::Unit::TestCase
  SAMPLE_MARKDOWN = <<~MD
    # 2026-04-15 AWS まとめ

    ## [Art1](https://x)

    - 要点1
    - 要点2
  MD

  def setup
    @fake = FakeRunner.new(SAMPLE_MARKDOWN)
    @summarizer = CloudKnowledgeDb::DailySummarizer.new(model: 'opus')
    @summarizer.instance_variable_set(:@runner, @fake)
  end

  def test_summarize_returns_markdown
    md = @summarizer.summarize(provider_short: 'aws', date: '2026-04-15', translated_articles: [
      { title: 'Art1', url: 'https://x', body_ja: '本文1' }
    ])
    assert_match(/# 2026-04-15 AWS まとめ/, md)
  end

  def test_prompt_includes_articles
    @summarizer.summarize(provider_short: 'aws', date: '2026-04-15',
                          translated_articles: [{ title: 'T1', url: 'U1', body_ja: 'B1' }])
    assert_match(/T1/, @fake.last_prompt)
    assert_match(/U1/, @fake.last_prompt)
    assert_match(/B1/, @fake.last_prompt)
  end

  def test_prompt_instructs_heading_link_format
    @summarizer.summarize(provider_short: 'aws', date: '2026-04-15',
                          translated_articles: [{ title: 'T1', url: 'U1', body_ja: 'B1' }])
    assert_match(/## \[<タイトル>\]\(<URL>\)/, @fake.last_prompt,
                 'system prompt must tell the model to emit heading-as-link format')
    assert_match(/末尾に単独のリンク行/, @fake.last_prompt,
                 'system prompt must forbid a trailing bare link line')
  end
end
```

- [ ] **Step 5.2: Run to see failure**

Run:
```bash
cd ~/dev/src/github.com/bash0C7/cloud-knowledge-db
bundle exec rake test TEST=test/test_daily_summarizer.rb
```

Expected: `test_prompt_instructs_heading_link_format` FAILS (old prompt says `## <タイトル>` and `最後にリンクを付ける`).

- [ ] **Step 5.3: Update DailySummarizer system prompt**

Edit `lib/cloud_knowledge_db/daily_summarizer.rb`. Replace `SYSTEM_PROMPT` block with:

```ruby
    SYSTEM_PROMPT = <<~JA.freeze
      あなたはクラウドプラットフォームの公式技術ブログ新着記事をまとめるテクニカルライターです。
      与えられた1日分の翻訳済み記事リストから、以下の構造のMarkdown記事を作成してください。
      規則:
        - 見出しは「# YYYY-MM-DD <PROVIDER> まとめ」とする。
        - 各記事は「## [<タイトル>](<URL>)」の形式で見出し全体をリンクにし、その配下に要点3つ以内の箇条書きを置く。
        - 末尾に単独のリンク行（例: `[記事リンク](...)` やベアURL）を出力してはならない。
        - 文体は技術文書として中立な「です/ます」調。スラング・方言・絵文字・装飾語尾は禁止。
        - 出力は本文Markdownのみ。前置きや結語は不要。
    JA
```

- [ ] **Step 5.4: Run daily summarizer tests to verify green**

Run:
```bash
cd ~/dev/src/github.com/bash0C7/cloud-knowledge-db
bundle exec rake test TEST=test/test_daily_summarizer.rb
```

Expected: all 4 tests PASS.

- [ ] **Step 5.5: Run full repo test suite**

Run:
```bash
cd ~/dev/src/github.com/bash0C7/cloud-knowledge-db
bundle exec rake test
```

Expected: all tests PASS.

- [ ] **Step 5.6: Commit**

```bash
cd ~/dev/src/github.com/bash0C7/cloud-knowledge-db
git add lib/cloud_knowledge_db/daily_summarizer.rb test/test_daily_summarizer.rb
git commit -m "$(cat <<'EOF'
feat(summarizer): emit headings as clickable links

Change daily-summary prompt so each article heading is
`## [<title>](<url>)` and forbid the trailing bare `[記事リンク]` line.
Gives the esa reader a single clickable section title instead of
hunting for a URL line at the bottom of each block.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Cross-repo smoke verification

**Files:** none (verification only)

- [ ] **Step 6.1: cloud-blog-collector full test suite**

Run:
```bash
cd ~/dev/src/github.com/bash0C7/cloud-blog-collector
bundle exec rake test
```

Expected: all tests PASS.

- [ ] **Step 6.2: cloud-knowledge-db full test suite**

Run:
```bash
cd ~/dev/src/github.com/bash0C7/cloud-knowledge-db
bundle exec rake test
```

Expected: all tests PASS.

- [ ] **Step 6.3: Confirm contamination scan still clean**

Run:
```bash
cd ~/dev/src/github.com/bash0C7/cloud-knowledge-db
bundle exec rake test TEST=test/test_contamination.rb
```

Expected: PASS. Our Translator/DailySummarizer prompt edits must not leak gyaru/dialect tokens.

- [ ] **Step 6.4: Report status to user**

After all green, summarize:

1. Commits landed per repo.
2. Reminder that existing DB URLs and shipped esa posts are not retroactively fixed (per spec non-goal).
3. Ask the user whether to run a small-scope `APP_ENV=test SINCE=... bundle exec rake daily` smoke to verify end-to-end (gemma4 translation quality + URL shape + heading link in a real esa post) before the next production daily run.
