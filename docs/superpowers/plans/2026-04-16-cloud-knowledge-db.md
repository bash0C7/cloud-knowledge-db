# cloud-knowledge-db Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** AWS / Google Cloud / Google Workspace / GitLab 公式blog を SSOT として日次収集・Haiku英→日翻訳・SQLite格納・esa投稿し、chiebukuro-mcp 経由で対話深掘り可能にする。

**Architecture:** orchestrator (cloud-knowledge-db) + 1つのcollector gem (cloud-blog-collector) + 既存store gem (ruby-knowledge-store) 流用。4-phase pipeline (fetch → translate → import → esa)。Ruby Anthropic SDK直叩き、CLI不使用（CLAUDE.md口調コンタミ防止）。Runtime model resolution。

**Tech Stack:** Ruby 4.0.1, test-unit (xUnit), Anthropic Ruby SDK (`anthropic` gem), `rss`/`nokogiri` for parsing, `faraday` for HTTP, `sqlite3` + `sqlite-vec` (via ruby-knowledge-store), esa API (Net::HTTP).

**Spec:** `docs/superpowers/specs/2026-04-16-cloud-knowledge-db-design.md`

---

## Conventions (apply to all tasks)

- Always run Ruby commands via `bundle exec`.
- After each task, commit with conventional commits prefix (`feat:` / `fix:` / `test:` / `chore:` / `docs:`). All commit messages in **English**.
- Test framework: **test-unit** (xUnit style). Test file naming: `test/test_<subject>.rb`.
- TDD discipline: Red → Green → Refactor. Write failing test first, run to confirm fail, then implement, confirm pass, commit.
- Working directory: `/Users/bash/dev/src/github.com/bash0C7/cloud-knowledge-db` unless explicitly noted.
- Sibling repos: `../ruby-knowledge-store` and (newly created in Phase B) `../cloud-blog-collector`.
- Bundler config: `bundle config set --local path 'vendor/bundle'` (already set in repo).
- All commits should include `.claude/` directory contents per user's global rule.

---

# Phase A — Foundation (cloud-knowledge-db repo)

## Task 1: Project skeleton

**Files:**
- Create: `.ruby-version`
- Create: `Gemfile`
- Create: `Rakefile`
- Create: `lib/cloud_knowledge_db.rb`
- Create: `test/test_helper.rb`

- [ ] **Step 1: Create `.ruby-version`**

```
4.0.1
```

- [ ] **Step 2: Create `Gemfile`**

```ruby
# frozen_string_literal: true
source 'https://rubygems.org'

ruby '4.0.1'

gem 'sqlite3'
gem 'sqlite-vec'
gem 'informers'
gem 'mcp'
gem 'anthropic'
gem 'faraday'
gem 'nokogiri'
gem 'rss'

gem 'ruby_knowledge_store',  path: '../ruby-knowledge-store'
gem 'cloud_blog_collector',  path: '../cloud-blog-collector'

group :test do
  gem 'rake'
  gem 'test-unit'
end
```

- [ ] **Step 3: Create stub `Rakefile`**

```ruby
# frozen_string_literal: true
require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.test_files = FileList['test/test_*.rb']
  t.verbose = true
end

task default: :test
```

- [ ] **Step 4: Create top-level `lib/cloud_knowledge_db.rb`**

```ruby
# frozen_string_literal: true

module CloudKnowledgeDb
  VERSION = '0.0.1'
end
```

- [ ] **Step 5: Create `test/test_helper.rb`**

```ruby
# frozen_string_literal: true

ENV['APP_ENV'] ||= 'test'

require 'bundler/setup'
require 'test/unit'
require 'cloud_knowledge_db'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
```

- [ ] **Step 6: Configure bundler local path and install (skip cloud-blog-collector dep first)**

Temporarily comment out `gem 'cloud_blog_collector'` line in Gemfile (it doesn't exist yet — added in Phase B).

```bash
bundle config set --local path 'vendor/bundle'
bundle install
```

Expected: bundle resolves successfully, `vendor/bundle/` populated.

- [ ] **Step 7: Sanity smoke test**

```bash
bundle exec rake test
```

Expected: `0 tests, 0 assertions, 0 failures, 0 errors`. (No tests yet, but rake invoke succeeds.)

- [ ] **Step 8: Commit**

```bash
git add .ruby-version Gemfile Gemfile.lock Rakefile lib/cloud_knowledge_db.rb test/test_helper.rb
git commit -m "chore: bootstrap cloud-knowledge-db ruby project skeleton"
```

---

## Task 2: Config module

**Files:**
- Create: `lib/cloud_knowledge_db/config.rb`
- Create: `config/sources.yml` (stub)
- Create: `config/environments/development.yml`
- Create: `config/environments/test.yml`
- Create: `config/environments/production.yml`
- Create: `test/test_config.rb`

- [ ] **Step 1: Write the failing test `test/test_config.rb`**

```ruby
# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/config'

class ConfigTest < Test::Unit::TestCase
  def test_load_returns_merged_sources_and_env
    cfg = CloudKnowledgeDb::Config.load
    assert(cfg.key?('sources'), "config should have 'sources' key from sources.yml")
    assert(cfg.key?('db_path'), "config should have 'db_path' key from environments/test.yml")
    assert(cfg.key?('models'),  "config should have 'models' key from environments/test.yml")
  end

  def test_resolve_model_returns_short_name
    cfg = CloudKnowledgeDb::Config.load
    assert_equal 'haiku', cfg['models']['translator']
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bundle exec ruby -Ilib -Itest test/test_config.rb
```

Expected: `LoadError: cannot load such file -- cloud_knowledge_db/config`.

- [ ] **Step 3: Create `lib/cloud_knowledge_db/config.rb`**

```ruby
# frozen_string_literal: true
require 'yaml'

module CloudKnowledgeDb
  module Config
    APP_ENV    = ENV.fetch('APP_ENV', 'development')
    CONFIG_DIR = File.expand_path('../../config', __dir__)

    def self.load
      sources  = YAML.load_file(File.join(CONFIG_DIR, 'sources.yml'))
      env_file = File.join(CONFIG_DIR, 'environments', "#{APP_ENV}.yml")
      abort "Unknown APP_ENV: #{APP_ENV} (no file: #{env_file})" unless File.exist?(env_file)
      env_cfg  = YAML.load_file(env_file)
      sources.merge(env_cfg)
    end

    # 書き込み系タスクを特定 Mac に限定する暫定ガード。
    # ALLOW_WRITE=1 で一時バイパス可。allowed_write_host 未設定の env は素通し。
    def self.ensure_write_host!
      host = load['allowed_write_host']
      return unless host
      return if ENV['ALLOW_WRITE'] == '1'
      current = `scutil --get LocalHostName 2>/dev/null`.strip
      current = `hostname 2>/dev/null`.strip.split('.').first if current.empty?
      return if current == host
      abort "Refusing to write: current host '#{current}' != allowed_write_host '#{host}' (APP_ENV=#{APP_ENV}). Set ALLOW_WRITE=1 to bypass."
    end
  end
end
```

- [ ] **Step 4: Create stub `config/sources.yml`**

```yaml
sources:
  aws_blog:
    short_name: aws
    feed_url: https://aws.amazon.com/blogs/aws/feed/
    adapter: rss
    source_article: aws/blogs/news
    source_original: aws/blogs/news/original
```

- [ ] **Step 5: Create `config/environments/test.yml`**

```yaml
db_path: db/cloud_knowledge_test.db

esa:
  team: bist
  wip: true
  sources:
    aws_blog:
      category: test/cloud-trunk-changes/aws

models:
  translator:       haiku
  classifier:       haiku
  daily_summarizer: haiku
  default:          haiku
```

- [ ] **Step 6: Create `config/environments/development.yml`**

```yaml
db_path: db/cloud_knowledge_development.db

esa:
  team: bist
  wip: true
  sources:
    aws_blog:
      category: development/cloud-trunk-changes/aws

models:
  translator:       haiku
  classifier:       haiku
  daily_summarizer: sonnet
  default:          sonnet
```

- [ ] **Step 7: Create `config/environments/production.yml`**

```yaml
db_path: db/cloud_knowledge.db
db_copy_to: ~/Library/Mobile Documents/com~apple~CloudDocs/chiebukuro-mcp/db/cloud_knowledge.db

allowed_write_host: MacBook-Air-M3

esa:
  team: bash-trunk-changes
  wip: false
  sources:
    aws_blog:
      category: production/cloud-trunk-changes/aws

models:
  translator:       haiku
  classifier:       haiku
  daily_summarizer: opus
  default:          sonnet
```

- [ ] **Step 8: Run test to verify it passes**

```bash
bundle exec rake test
```

Expected: 2 tests, 3+ assertions, 0 failures.

- [ ] **Step 9: Commit**

```bash
git add lib/cloud_knowledge_db/config.rb config/ test/test_config.rb
git commit -m "feat: add Config module with APP_ENV-aware loading and host guard"
```

---

## Task 3: ModelResolver

**Files:**
- Create: `lib/cloud_knowledge_db/model_resolver.rb`
- Create: `test/test_model_resolver.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/model_resolver'

class ModelResolverTest < Test::Unit::TestCase
  FakeModel  = Struct.new(:id)
  FakeModels = Struct.new(:data)
  class FakeClient
    def initialize(ids); @ids = ids; end
    def models
      Object.new.tap do |o|
        ids = @ids
        o.define_singleton_method(:list) { FakeModels.new(ids.map { |i| FakeModel.new(i) }) }
      end
    end
  end

  def setup
    %w[CLOUD_KB_PIN_HAIKU CLOUD_KB_PIN_SONNET CLOUD_KB_PIN_OPUS].each { |k| ENV.delete(k) }
  end

  def test_resolve_picks_latest_per_family
    client = FakeClient.new([
      'claude-haiku-3-5-20240101',
      'claude-haiku-4-5-20251001',
      'claude-sonnet-4-6',
      'claude-opus-4-6',
      'claude-opus-3-5'
    ])
    r = CloudKnowledgeDb::ModelResolver.new(client: client)
    assert_equal 'claude-haiku-4-5-20251001', r.resolve(:haiku)
    assert_equal 'claude-sonnet-4-6',          r.resolve(:sonnet)
    assert_equal 'claude-opus-4-6',            r.resolve(:opus)
  end

  def test_env_pin_overrides_resolution
    ENV['CLOUD_KB_PIN_HAIKU'] = 'claude-haiku-PINNED'
    client = FakeClient.new(['claude-haiku-4-5-20251001'])
    r = CloudKnowledgeDb::ModelResolver.new(client: client)
    assert_equal 'claude-haiku-PINNED', r.resolve(:haiku)
  end

  def test_unknown_family_raises
    r = CloudKnowledgeDb::ModelResolver.new(client: FakeClient.new([]))
    assert_raise(ArgumentError) { r.resolve(:flash) }
  end

  def test_no_candidates_raises
    r = CloudKnowledgeDb::ModelResolver.new(client: FakeClient.new(['claude-sonnet-4-6']))
    assert_raise(RuntimeError) { r.resolve(:haiku) }
  end
end
```

- [ ] **Step 2: Run test to verify failure**

```bash
bundle exec ruby -Ilib -Itest test/test_model_resolver.rb
```

Expected: LoadError for `cloud_knowledge_db/model_resolver`.

- [ ] **Step 3: Implement `lib/cloud_knowledge_db/model_resolver.rb`**

```ruby
# frozen_string_literal: true

module CloudKnowledgeDb
  class ModelResolver
    FAMILIES = %w[haiku sonnet opus].freeze

    def initialize(client:)
      @client = client
      @cache  = {}
    end

    # @param family [String, Symbol]
    # @return [String] full model id
    def resolve(family)
      family = family.to_s
      raise ArgumentError, "unknown family: #{family}" unless FAMILIES.include?(family)

      pin = ENV["CLOUD_KB_PIN_#{family.upcase}"]
      return pin if pin && !pin.empty?

      @cache[family] ||= fetch_latest(family)
    end

    private

    def fetch_latest(family)
      models = @client.models.list
      candidates = models.data.select { |m| m.id.start_with?("claude-#{family}-") }
      raise "no model for family: #{family}" if candidates.empty?
      candidates.max_by { |m| version_tuple(m.id) }.id
    end

    def version_tuple(id)
      id.scan(/\d+/).map(&:to_i)
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
bundle exec rake test
```

Expected: 4 model_resolver tests pass + previous tests still pass.

- [ ] **Step 5: Commit**

```bash
git add lib/cloud_knowledge_db/model_resolver.rb test/test_model_resolver.rb
git commit -m "feat: add ModelResolver with runtime /v1/models query and env pin"
```

---

## Task 4: TrunkBookmark (port from ruby-knowledge-db)

**Files:**
- Create: `lib/cloud_knowledge_db/trunk_bookmark.rb`
- Create: `test/test_trunk_bookmark.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/trunk_bookmark'
require 'tmpdir'
require 'fileutils'

class TrunkBookmarkTest < Test::Unit::TestCase
  TB = CloudKnowledgeDb::TrunkBookmark

  def test_load_missing_file_returns_empty
    Dir.mktmpdir do |dir|
      assert_equal({}, TB.load(File.join(dir, 'missing.yml')))
    end
  end

  def test_save_then_load_round_trip
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'last_run.yml')
      data = TB.mark_started({}, 'aws_blog', before: '2026-04-16', at: Time.parse('2026-04-16T09:00:00+09:00'))
      TB.save(path, data)
      loaded = TB.load(path)
      assert_equal '2026-04-16', loaded['aws_blog']['last_started_before']
    end
  end

  def test_status_detects_wip
    data = TB.mark_started({}, 'aws_blog', before: '2026-04-16', at: Time.now)
    snap = TB.status(data, %w[aws_blog gcp_blog])
    assert(snap['aws_blog'][:wip])
    assert_nil(snap['gcp_blog'][:last_started_before])
  end

  def test_status_completed_clears_wip
    data = {}
    data = TB.mark_started(data,   'aws_blog', before: '2026-04-16', at: Time.now)
    data = TB.mark_completed(data, 'aws_blog', before: '2026-04-16', at: Time.now)
    snap = TB.status(data, %w[aws_blog])
    assert_false(snap['aws_blog'][:wip])
  end

  def test_recommended_since_floor_picks_min
    data = {}
    data = TB.mark_completed(data, 'aws_blog', before: '2026-04-15', at: Time.now)
    data = TB.mark_completed(data, 'gcp_blog', before: '2026-04-10', at: Time.now)
    floor = TB.recommended_since_floor(data, %w[aws_blog gcp_blog])
    assert_equal '2026-04-10', floor
  end

  def test_recommended_since_floor_nil_if_any_missing
    data = TB.mark_completed({}, 'aws_blog', before: '2026-04-15', at: Time.now)
    floor = TB.recommended_since_floor(data, %w[aws_blog gcp_blog])
    assert_nil(floor)
  end
end
```

- [ ] **Step 2: Run test to verify failure**

```bash
bundle exec rake test
```

Expected: LoadError for `cloud_knowledge_db/trunk_bookmark`.

- [ ] **Step 3: Implement `lib/cloud_knowledge_db/trunk_bookmark.rb`**

```ruby
# frozen_string_literal: true
require 'yaml'
require 'fileutils'
require 'time'

module CloudKnowledgeDb
  module TrunkBookmark
    module_function

    def load(path)
      return {} unless File.exist?(path)
      YAML.load_file(path) || {}
    end

    def save(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, data.to_yaml)
    end

    def mark_started(data, source_key, before:, at: Time.now)
      entry = data[source_key].is_a?(Hash) ? data[source_key].dup : {}
      entry['last_started_at']     = at.iso8601
      entry['last_started_before'] = before.to_s
      data[source_key] = entry
      data
    end

    def mark_completed(data, source_key, before:, at: Time.now, models_used: nil)
      entry = data[source_key].is_a?(Hash) ? data[source_key].dup : {}
      entry['last_completed_at']     = at.iso8601
      entry['last_completed_before'] = before.to_s
      entry['models_used']           = models_used if models_used
      data[source_key] = entry
      data
    end

    def status(data, source_keys)
      source_keys.each_with_object({}) do |key, acc|
        entry     = data[key].is_a?(Hash) ? data[key] : {}
        started   = entry['last_started_before']
        completed = entry['last_completed_before']
        wip = !started.nil? && (completed.nil? || started > completed)
        acc[key] = {
          last_started_at:       entry['last_started_at'],
          last_started_before:   started,
          last_completed_at:     entry['last_completed_at'],
          last_completed_before: completed,
          wip:                   wip,
          recommended_since:     completed
        }
      end
    end

    def recommended_since_floor(data, source_keys)
      completed = source_keys.map do |key|
        entry = data[key].is_a?(Hash) ? data[key] : {}
        entry['last_completed_before']
      end
      return nil if completed.any?(&:nil?)
      completed.min
    end
  end
end
```

- [ ] **Step 4: Run tests**

```bash
bundle exec rake test
```

Expected: 6 trunk_bookmark tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/cloud_knowledge_db/trunk_bookmark.rb test/test_trunk_bookmark.rb
git commit -m "feat: add TrunkBookmark with two-stage commit semantics and models_used field"
```

---

# Phase B — cloud-blog-collector gem (sibling repo)

## Task 5: Gem skeleton

**Files (in `../cloud-blog-collector/`):**
- Create: `cloud-blog-collector/cloud_blog_collector.gemspec`
- Create: `cloud-blog-collector/Gemfile`
- Create: `cloud-blog-collector/Rakefile`
- Create: `cloud-blog-collector/lib/cloud_blog_collector.rb`
- Create: `cloud-blog-collector/lib/cloud_blog_collector/version.rb`
- Create: `cloud-blog-collector/test/test_helper.rb`
- Create: `cloud-blog-collector/.ruby-version`
- Create: `cloud-blog-collector/.gitignore`

- [ ] **Step 1: Create the new gem directory and init git**

```bash
mkdir -p ../cloud-blog-collector/lib/cloud_blog_collector ../cloud-blog-collector/lib/cloud_blog_collector/adapters ../cloud-blog-collector/test/fixtures
cd ../cloud-blog-collector && git init -b main && cd -
```

- [ ] **Step 2: Create `../cloud-blog-collector/.ruby-version`**

```
4.0.1
```

- [ ] **Step 3: Create `../cloud-blog-collector/.gitignore`**

```
/vendor/bundle/
/.bundle/
*.gem
.DS_Store
```

- [ ] **Step 4: Create `../cloud-blog-collector/lib/cloud_blog_collector/version.rb`**

```ruby
# frozen_string_literal: true
module CloudBlogCollector
  VERSION = '0.0.1'
end
```

- [ ] **Step 5: Create `../cloud-blog-collector/lib/cloud_blog_collector.rb`**

```ruby
# frozen_string_literal: true
require_relative 'cloud_blog_collector/version'
require_relative 'cloud_blog_collector/source_registry'
require_relative 'cloud_blog_collector/collector'
require_relative 'cloud_blog_collector/adapters/rss'
require_relative 'cloud_blog_collector/adapters/web_fetch'
require_relative 'cloud_blog_collector/adapters/chrome'
require_relative 'cloud_blog_collector/adapters/classmethod'

module CloudBlogCollector
end
```

- [ ] **Step 6: Create `../cloud-blog-collector/cloud_blog_collector.gemspec`**

```ruby
# frozen_string_literal: true
require_relative 'lib/cloud_blog_collector/version'

Gem::Specification.new do |spec|
  spec.name          = 'cloud_blog_collector'
  spec.version       = CloudBlogCollector::VERSION
  spec.authors       = ['bash0C7']
  spec.summary       = 'Cloud platform official blog collector with RSS/WebFetch/Chrome adapters.'
  spec.required_ruby_version = '>= 4.0.0'
  spec.files         = Dir['lib/**/*.rb']
  spec.require_paths = ['lib']

  spec.add_dependency 'rss'
  spec.add_dependency 'nokogiri'
  spec.add_dependency 'faraday'
end
```

- [ ] **Step 7: Create `../cloud-blog-collector/Gemfile`**

```ruby
# frozen_string_literal: true
source 'https://rubygems.org'
gemspec

group :test do
  gem 'rake'
  gem 'test-unit'
end
```

- [ ] **Step 8: Create `../cloud-blog-collector/Rakefile`**

```ruby
# frozen_string_literal: true
require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test' << 'lib'
  t.test_files = FileList['test/test_*.rb']
  t.verbose = true
end

task default: :test
```

- [ ] **Step 9: Create `../cloud-blog-collector/test/test_helper.rb`**

```ruby
# frozen_string_literal: true
require 'bundler/setup'
require 'test/unit'
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
```

- [ ] **Step 10: Bundle install (collector gem standalone)**

```bash
cd ../cloud-blog-collector
bundle config set --local path 'vendor/bundle'
bundle install
cd -
```

Expected: bundle resolves successfully.

- [ ] **Step 11: Commit (in the collector repo)**

```bash
cd ../cloud-blog-collector
git add .
git commit -m "chore: bootstrap cloud-blog-collector gem skeleton"
cd -
```

---

## Task 6: SourceRegistry + Collector main class

**Files (in `../cloud-blog-collector/`):**
- Create: `lib/cloud_blog_collector/source_registry.rb`
- Create: `lib/cloud_blog_collector/collector.rb`
- Create: `test/test_source_registry.rb`
- Create: `test/test_collector.rb`

- [ ] **Step 1: Write failing tests `test/test_source_registry.rb`**

```ruby
# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_blog_collector/source_registry'

class SourceRegistryTest < Test::Unit::TestCase
  def test_resolves_known_adapters
    %i[rss web_fetch chrome classmethod].each do |key|
      adapter = CloudBlogCollector::SourceRegistry.adapter_class(key.to_s)
      assert_not_nil adapter, "should resolve adapter for #{key}"
    end
  end

  def test_unknown_adapter_raises
    assert_raise(ArgumentError) { CloudBlogCollector::SourceRegistry.adapter_class('telepathy') }
  end
end
```

- [ ] **Step 2: Write failing test `test/test_collector.rb`**

```ruby
# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_blog_collector/collector'

class CollectorTest < Test::Unit::TestCase
  class FakeAdapter
    def initialize(_cfg); end
    def fetch(since:, before:); [{ url: 'u', title: 't', content_original: 'c', published_at: Time.now, source: 'src' }]; end
  end

  def test_delegates_to_adapter
    cfg = { 'adapter' => 'fake', 'source_article' => 'x', 'source_original' => 'x/original' }
    collector = CloudBlogCollector::Collector.new(cfg, adapter_class: FakeAdapter)
    out = collector.fetch(since: nil, before: nil)
    assert_equal 1, out.length
    assert_equal 'src', out.first[:source]
  end
end
```

- [ ] **Step 3: Run tests, verify failure**

```bash
cd ../cloud-blog-collector && bundle exec rake test ; cd -
```

Expected: LoadError for source_registry / collector.

- [ ] **Step 4: Implement `lib/cloud_blog_collector/source_registry.rb`**

```ruby
# frozen_string_literal: true
require_relative 'adapters/rss'
require_relative 'adapters/web_fetch'
require_relative 'adapters/chrome'
require_relative 'adapters/classmethod'

module CloudBlogCollector
  module SourceRegistry
    ADAPTERS = {
      'rss'         => Adapters::Rss,
      'web_fetch'   => Adapters::WebFetch,
      'chrome'      => Adapters::Chrome,
      'classmethod' => Adapters::Classmethod
    }.freeze

    def self.adapter_class(name)
      ADAPTERS[name.to_s] or raise ArgumentError, "unknown adapter: #{name.inspect}"
    end
  end
end
```

- [ ] **Step 5: Create empty adapter stubs (will be filled in next tasks)**

Create `lib/cloud_blog_collector/adapters/rss.rb`:
```ruby
# frozen_string_literal: true
module CloudBlogCollector
  module Adapters
    class Rss
      def initialize(cfg); @cfg = cfg; end
      def fetch(since:, before:); []; end
    end
  end
end
```

Create the same shape for `web_fetch.rb`, `chrome.rb`, `classmethod.rb` (replace class name to match: `WebFetch`, `Chrome`, `Classmethod`).

- [ ] **Step 6: Implement `lib/cloud_blog_collector/collector.rb`**

```ruby
# frozen_string_literal: true
require_relative 'source_registry'

module CloudBlogCollector
  class Collector
    # @param cfg [Hash] sources.yml entry. Must include 'adapter', 'source_article'.
    # @param adapter_class [Class, nil] override for testing
    def initialize(cfg, adapter_class: nil)
      @cfg     = cfg
      @adapter = (adapter_class || SourceRegistry.adapter_class(cfg['adapter'])).new(cfg)
    end

    # @return [Array<Hash>] each: {url:, title:, content_original:, published_at:, source:}
    def fetch(since:, before:)
      @adapter.fetch(since: since, before: before)
    end
  end
end
```

- [ ] **Step 7: Run tests, verify pass**

```bash
cd ../cloud-blog-collector && bundle exec rake test ; cd -
```

Expected: 3 tests pass.

- [ ] **Step 8: Commit**

```bash
cd ../cloud-blog-collector
git add lib/cloud_blog_collector.rb lib/cloud_blog_collector/source_registry.rb lib/cloud_blog_collector/collector.rb lib/cloud_blog_collector/adapters/ test/test_source_registry.rb test/test_collector.rb
git commit -m "feat: add SourceRegistry, Collector facade, and adapter stubs"
cd -
```

---

## Task 7: RssAdapter implementation

**Files (in `../cloud-blog-collector/`):**
- Modify: `lib/cloud_blog_collector/adapters/rss.rb`
- Create: `test/fixtures/aws_rss_sample.xml`
- Create: `test/test_rss_adapter.rb`

- [ ] **Step 1: Create fixture `test/fixtures/aws_rss_sample.xml`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>AWS News Blog</title>
    <item>
      <title>New Amazon EC2 Instance Type Launched</title>
      <link>https://aws.amazon.com/blogs/aws/new-ec2-instance/</link>
      <description><![CDATA[<p>Today we are launching a new EC2 instance...</p>]]></description>
      <pubDate>Tue, 15 Apr 2026 10:00:00 +0000</pubDate>
      <guid>https://aws.amazon.com/blogs/aws/new-ec2-instance/</guid>
    </item>
    <item>
      <title>Old article we should filter out</title>
      <link>https://aws.amazon.com/blogs/aws/old/</link>
      <description><![CDATA[<p>old content</p>]]></description>
      <pubDate>Tue, 01 Apr 2026 10:00:00 +0000</pubDate>
      <guid>https://aws.amazon.com/blogs/aws/old/</guid>
    </item>
  </channel>
</rss>
```

- [ ] **Step 2: Write failing test `test/test_rss_adapter.rb`**

```ruby
# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_blog_collector/adapters/rss'

class RssAdapterTest < Test::Unit::TestCase
  FIXTURE = File.expand_path('fixtures/aws_rss_sample.xml', __dir__)

  def setup
    cfg = {
      'feed_url'        => "file://#{FIXTURE}",
      'source_article'  => 'aws/blogs/news',
      'source_original' => 'aws/blogs/news/original'
    }
    @adapter = CloudBlogCollector::Adapters::Rss.new(cfg)
  end

  def test_fetch_returns_records_within_window
    out = @adapter.fetch(since: Time.parse('2026-04-10'), before: Time.parse('2026-04-20'))
    assert_equal 1, out.length
    rec = out.first
    assert_equal 'New Amazon EC2 Instance Type Launched', rec[:title]
    assert_equal 'https://aws.amazon.com/blogs/aws/new-ec2-instance/', rec[:url]
    assert_equal 'aws/blogs/news/original', rec[:source]
    assert_match(/EC2 instance/, rec[:content_original])
  end

  def test_fetch_with_nil_since_returns_all_before
    out = @adapter.fetch(since: nil, before: Time.parse('2026-04-20'))
    assert_equal 2, out.length
  end

  def test_fetch_excludes_at_or_after_before
    out = @adapter.fetch(since: nil, before: Time.parse('2026-04-15'))
    titles = out.map { |r| r[:title] }
    assert_false(titles.include?('New Amazon EC2 Instance Type Launched'))
  end
end
```

- [ ] **Step 3: Run test to verify failure**

```bash
cd ../cloud-blog-collector && bundle exec ruby -Ilib -Itest test/test_rss_adapter.rb ; cd -
```

Expected: failures (returns empty array stub).

- [ ] **Step 4: Implement `lib/cloud_blog_collector/adapters/rss.rb`**

```ruby
# frozen_string_literal: true
require 'rss'
require 'open-uri'
require 'time'

module CloudBlogCollector
  module Adapters
    class Rss
      def initialize(cfg)
        @cfg = cfg
      end

      # @param since [Time, nil] inclusive lower bound (nil = no lower bound)
      # @param before [Time, nil] exclusive upper bound (nil = no upper bound)
      # @return [Array<Hash>]
      def fetch(since:, before:)
        feed = ::RSS::Parser.parse(URI.open(@cfg['feed_url']).read, false)
        items = extract_items(feed)
        items
          .select { |item| in_window?(item[:published_at], since, before) }
          .map    { |item| build_record(item) }
      end

      private

      def extract_items(feed)
        if feed.respond_to?(:items)
          feed.items.map do |it|
            {
              title:        (it.respond_to?(:title) && it.title.respond_to?(:content) ? it.title.content : it.title.to_s),
              url:          (it.respond_to?(:link) && it.link.respond_to?(:href) ? it.link.href : it.link.to_s),
              description:  (it.respond_to?(:description) ? it.description.to_s : (it.respond_to?(:content) ? it.content.to_s : '')),
              published_at: (it.respond_to?(:pubDate) ? it.pubDate : (it.respond_to?(:date) ? it.date : nil))
            }
          end
        else
          []
        end
      end

      def in_window?(t, since, before)
        return false if t.nil?
        return false if since  && t < since
        return false if before && t >= before
        true
      end

      def build_record(item)
        {
          url:              item[:url],
          title:            item[:title],
          content_original: item[:description],
          published_at:     item[:published_at],
          source:           @cfg['source_original']
        }
      end
    end
  end
end
```

- [ ] **Step 5: Run tests, verify pass**

```bash
cd ../cloud-blog-collector && bundle exec rake test ; cd -
```

Expected: 3 rss adapter tests pass + earlier tests still pass.

- [ ] **Step 6: Commit**

```bash
cd ../cloud-blog-collector
git add lib/cloud_blog_collector/adapters/rss.rb test/fixtures/aws_rss_sample.xml test/test_rss_adapter.rb
git commit -m "feat: implement RssAdapter with window filter and AWS-style fixture test"
cd -
```

---

## Task 8: WebFetchAdapter (HTML scraping fallback)

**Files (in `../cloud-blog-collector/`):**
- Modify: `lib/cloud_blog_collector/adapters/web_fetch.rb`
- Create: `test/fixtures/sample_blog_index.html`
- Create: `test/test_web_fetch_adapter.rb`

- [ ] **Step 1: Create fixture `test/fixtures/sample_blog_index.html`**

```html
<!DOCTYPE html>
<html>
<body>
  <article class="blog-post">
    <h2><a href="/blog/post-2026-04-15">New Cloud Feature</a></h2>
    <time datetime="2026-04-15T10:00:00Z">April 15, 2026</time>
    <div class="excerpt">Description of the new feature.</div>
  </article>
  <article class="blog-post">
    <h2><a href="/blog/post-2026-04-01">Old Post</a></h2>
    <time datetime="2026-04-01T10:00:00Z">April 1, 2026</time>
    <div class="excerpt">Old.</div>
  </article>
</body>
</html>
```

- [ ] **Step 2: Write failing test `test/test_web_fetch_adapter.rb`**

```ruby
# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_blog_collector/adapters/web_fetch'

class WebFetchAdapterTest < Test::Unit::TestCase
  FIXTURE = File.expand_path('fixtures/sample_blog_index.html', __dir__)

  def setup
    cfg = {
      'index_url'         => "file://#{FIXTURE}",
      'item_selector'     => 'article.blog-post',
      'title_selector'    => 'h2 a',
      'link_selector'     => 'h2 a',
      'date_selector'     => 'time',
      'date_attr'         => 'datetime',
      'excerpt_selector'  => '.excerpt',
      'base_url'          => 'https://example.com',
      'source_article'    => 'gws/blogs/all',
      'source_original'   => 'gws/blogs/all/original'
    }
    @adapter = CloudBlogCollector::Adapters::WebFetch.new(cfg)
  end

  def test_fetch_filters_by_window
    out = @adapter.fetch(since: Time.parse('2026-04-10'), before: Time.parse('2026-04-20'))
    assert_equal 1, out.length
    assert_equal 'New Cloud Feature', out.first[:title]
    assert_equal 'https://example.com/blog/post-2026-04-15', out.first[:url]
    assert_equal 'gws/blogs/all/original', out.first[:source]
  end
end
```

- [ ] **Step 3: Run test, verify failure**

```bash
cd ../cloud-blog-collector && bundle exec ruby -Ilib -Itest test/test_web_fetch_adapter.rb ; cd -
```

- [ ] **Step 4: Implement `lib/cloud_blog_collector/adapters/web_fetch.rb`**

```ruby
# frozen_string_literal: true
require 'nokogiri'
require 'open-uri'
require 'time'
require 'uri'

module CloudBlogCollector
  module Adapters
    class WebFetch
      def initialize(cfg)
        @cfg = cfg
      end

      def fetch(since:, before:)
        doc = ::Nokogiri::HTML(URI.open(@cfg['index_url']).read)
        items = doc.css(@cfg['item_selector']).map { |node| extract_item(node) }
        items
          .select { |item| in_window?(item[:published_at], since, before) }
          .map    { |item| build_record(item) }
      end

      private

      def extract_item(node)
        title = node.css(@cfg['title_selector']).first&.text&.strip
        link  = node.css(@cfg['link_selector']).first&.[]('href')
        date  = node.css(@cfg['date_selector']).first&.[](@cfg['date_attr'] || 'datetime')
        body  = node.css(@cfg['excerpt_selector']).first&.text&.strip
        {
          title:        title,
          url:          absolutize(link),
          description:  body,
          published_at: (date ? Time.parse(date) : nil)
        }
      end

      def absolutize(link)
        return link if link.nil?
        URI.join(@cfg['base_url'], link).to_s
      end

      def in_window?(t, since, before)
        return false if t.nil?
        return false if since  && t < since
        return false if before && t >= before
        true
      end

      def build_record(item)
        {
          url:              item[:url],
          title:            item[:title],
          content_original: item[:description],
          published_at:     item[:published_at],
          source:           @cfg['source_original']
        }
      end
    end
  end
end
```

- [ ] **Step 5: Run tests, verify pass**

```bash
cd ../cloud-blog-collector && bundle exec rake test ; cd -
```

- [ ] **Step 6: Commit**

```bash
cd ../cloud-blog-collector
git add lib/cloud_blog_collector/adapters/web_fetch.rb test/fixtures/sample_blog_index.html test/test_web_fetch_adapter.rb
git commit -m "feat: implement WebFetchAdapter for HTML-only blogs"
cd -
```

---

## Task 9: ChromeAdapter stub (defer Chrome MCP integration)

**Files (in `../cloud-blog-collector/`):**
- Modify: `lib/cloud_blog_collector/adapters/chrome.rb`
- Create: `test/test_chrome_adapter.rb`

- [ ] **Step 1: Write failing test**

```ruby
# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_blog_collector/adapters/chrome'

class ChromeAdapterTest < Test::Unit::TestCase
  def test_fetch_raises_not_implemented
    a = CloudBlogCollector::Adapters::Chrome.new('source_original' => 'x')
    assert_raise(NotImplementedError) { a.fetch(since: nil, before: nil) }
  end
end
```

- [ ] **Step 2: Run test, verify failure**

- [ ] **Step 3: Implement `lib/cloud_blog_collector/adapters/chrome.rb`**

```ruby
# frozen_string_literal: true

module CloudBlogCollector
  module Adapters
    class Chrome
      def initialize(cfg)
        @cfg = cfg
      end

      def fetch(since:, before:)
        raise NotImplementedError,
          "Chrome MCP adapter is reserved for JS-rendered blogs. Implement when needed."
      end
    end
  end
end
```

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5: Commit**

```bash
cd ../cloud-blog-collector
git add lib/cloud_blog_collector/adapters/chrome.rb test/test_chrome_adapter.rb
git commit -m "feat: stub ChromeAdapter (raises NotImplementedError until needed)"
cd -
```

---

## Task 10: ClassmethodAdapter (RSS + tag filter)

**Files (in `../cloud-blog-collector/`):**
- Modify: `lib/cloud_blog_collector/adapters/classmethod.rb`
- Create: `test/fixtures/classmethod_rss_sample.xml`
- Create: `test/test_classmethod_adapter.rb`

- [ ] **Step 1: Create fixture `test/fixtures/classmethod_rss_sample.xml`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <item>
      <title>AWS Lambdaの新機能解説</title>
      <link>https://dev.classmethod.jp/articles/aws-lambda-new/</link>
      <description><![CDATA[Lambda の新機能について解説します。]]></description>
      <pubDate>Tue, 15 Apr 2026 10:00:00 +0000</pubDate>
      <category>AWS</category>
      <category>Lambda</category>
    </item>
    <item>
      <title>BigQuery のコスト最適化</title>
      <link>https://dev.classmethod.jp/articles/bq-cost/</link>
      <description><![CDATA[BigQuery を安く使う方法。]]></description>
      <pubDate>Tue, 15 Apr 2026 11:00:00 +0000</pubDate>
      <category>Google Cloud</category>
    </item>
    <item>
      <title>無関係なiOSの記事</title>
      <link>https://dev.classmethod.jp/articles/ios/</link>
      <description><![CDATA[iOSの話。]]></description>
      <pubDate>Tue, 15 Apr 2026 12:00:00 +0000</pubDate>
      <category>iOS</category>
    </item>
  </channel>
</rss>
```

- [ ] **Step 2: Write failing test `test/test_classmethod_adapter.rb`**

```ruby
# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_blog_collector/adapters/classmethod'

class ClassmethodAdapterTest < Test::Unit::TestCase
  FIXTURE = File.expand_path('fixtures/classmethod_rss_sample.xml', __dir__)

  def setup
    cfg = {
      'feed_url' => "file://#{FIXTURE}",
      'tag_to_source' => {
        'AWS'          => 'aws/classmethod',
        'Google Cloud' => 'gcp/classmethod',
        'Workspace'    => 'gws/classmethod',
        'GitLab'       => 'gitlab/classmethod'
      }
    }
    @adapter = CloudBlogCollector::Adapters::Classmethod.new(cfg)
  end

  def test_aws_article_routed_to_aws_classmethod_source
    out = @adapter.fetch(since: nil, before: Time.parse('2026-04-20'))
    aws = out.find { |r| r[:title] =~ /Lambda/ }
    assert_equal 'aws/classmethod', aws[:source]
  end

  def test_gcp_article_routed_to_gcp_classmethod_source
    out = @adapter.fetch(since: nil, before: Time.parse('2026-04-20'))
    gcp = out.find { |r| r[:title] =~ /BigQuery/ }
    assert_equal 'gcp/classmethod', gcp[:source]
  end

  def test_unrelated_articles_excluded
    out = @adapter.fetch(since: nil, before: Time.parse('2026-04-20'))
    assert_nil out.find { |r| r[:title] =~ /iOS/ }
  end
end
```

- [ ] **Step 3: Run test to verify failure.**

- [ ] **Step 4: Implement `lib/cloud_blog_collector/adapters/classmethod.rb`**

```ruby
# frozen_string_literal: true
require 'rss'
require 'open-uri'
require 'time'

module CloudBlogCollector
  module Adapters
    class Classmethod
      def initialize(cfg)
        @cfg = cfg
        @tag_to_source = cfg['tag_to_source'] || {}
      end

      def fetch(since:, before:)
        feed = ::RSS::Parser.parse(URI.open(@cfg['feed_url']).read, false)
        feed.items.each_with_object([]) do |item, acc|
          published_at = item.respond_to?(:pubDate) ? item.pubDate : (item.respond_to?(:date) ? item.date : nil)
          next unless in_window?(published_at, since, before)

          source = pick_source(item)
          next unless source

          acc << {
            url:              extract_link(item),
            title:            extract_text(item.title),
            content_original: item.description.to_s,
            published_at:     published_at,
            source:           source
          }
        end
      end

      private

      def in_window?(t, since, before)
        return false if t.nil?
        return false if since  && t < since
        return false if before && t >= before
        true
      end

      def pick_source(item)
        tags = (item.respond_to?(:categories) ? item.categories.map(&:content) : []).compact
        tag = tags.find { |c| @tag_to_source.key?(c) }
        @tag_to_source[tag]
      end

      def extract_link(item)
        item.respond_to?(:link) && item.link.respond_to?(:href) ? item.link.href : item.link.to_s
      end

      def extract_text(t)
        t.respond_to?(:content) ? t.content : t.to_s
      end
    end
  end
end
```

- [ ] **Step 5: Run, verify pass.**

- [ ] **Step 6: Commit**

```bash
cd ../cloud-blog-collector
git add lib/cloud_blog_collector/adapters/classmethod.rb test/fixtures/classmethod_rss_sample.xml test/test_classmethod_adapter.rb
git commit -m "feat: implement ClassmethodAdapter with category-tag routing"
cd -
```

---

# Phase C — LLM components (cloud-knowledge-db repo)

## Task 11: Wire cloud-blog-collector into cloud-knowledge-db Gemfile

**Files:**
- Modify: `Gemfile` (re-enable `gem 'cloud_blog_collector'`)
- Run: `bundle install`

- [ ] **Step 1: Re-enable the line** in cloud-knowledge-db `Gemfile`:

```ruby
gem 'cloud_blog_collector', path: '../cloud-blog-collector'
```

- [ ] **Step 2: Run bundle install**

```bash
bundle install
```

Expected: cloud_blog_collector resolved from local path.

- [ ] **Step 3: Smoke test require works**

```bash
bundle exec ruby -e "require 'cloud_blog_collector'; puts CloudBlogCollector::VERSION"
```

Expected: `0.0.1`.

- [ ] **Step 4: Commit**

```bash
git add Gemfile Gemfile.lock
git commit -m "chore: wire cloud-blog-collector gem dependency"
```

---

## Task 12: Translator (Haiku, contamination-safe)

**Files:**
- Create: `lib/cloud_knowledge_db/translator.rb`
- Create: `test/test_translator.rb`
- Create: `test/test_contamination.rb`
- Create: `test/support/fake_anthropic_client.rb`

- [ ] **Step 1: Create test helper `test/support/fake_anthropic_client.rb`**

```ruby
# frozen_string_literal: true
class FakeAnthropicClient
  attr_reader :calls

  def initialize(responses: [])
    @responses = responses
    @calls     = []
  end

  def messages
    @messages ||= MessagesProxy.new(self)
  end

  class MessagesProxy
    def initialize(client); @client = client; end
    def create(**kwargs)
      @client.calls << kwargs
      response = @client.instance_variable_get(:@responses).shift || default_response
      Object.new.tap do |o|
        text = response
        o.define_singleton_method(:content) { [Object.new.tap { |c| c.define_singleton_method(:text) { text } }] }
      end
    end
    private
    def default_response; '訳文サンプル'; end
  end

  def models
    raise NotImplementedError
  end
end
```

- [ ] **Step 2: Write failing translator test `test/test_translator.rb`**

```ruby
# frozen_string_literal: true
require_relative 'test_helper'
require_relative 'support/fake_anthropic_client'
require 'cloud_knowledge_db/translator'

class TranslatorTest < Test::Unit::TestCase
  class FixedResolver
    def resolve(_); 'claude-haiku-4-5-fixture'; end
  end

  def setup
    @client = FakeAnthropicClient.new(responses: ['翻訳された日本語テキスト'])
    @translator = CloudKnowledgeDb::Translator.new(client: @client, model_resolver: FixedResolver.new)
  end

  def test_translate_returns_text_from_client
    out = @translator.translate('English article body.')
    assert_equal '翻訳された日本語テキスト', out
  end

  def test_passes_haiku_model_id
    @translator.translate('hello')
    assert_equal 'claude-haiku-4-5-fixture', @client.calls.first[:model]
  end

  def test_uses_english_system_prompt_with_cache_control
    @translator.translate('hello')
    sys = @client.calls.first[:system]
    assert_kind_of Array, sys
    assert_match(/English-to-Japanese translator/, sys.first[:text])
    assert_equal 'ephemeral', sys.first[:cache_control][:type]
  end

  def test_user_message_is_the_article
    @translator.translate('article body')
    msg = @client.calls.first[:messages].first
    assert_equal 'user',         msg[:role]
    assert_equal 'article body', msg[:content]
  end
end
```

- [ ] **Step 3: Write contamination test `test/test_contamination.rb`**

```ruby
# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/translator'

class ContaminationTest < Test::Unit::TestCase
  CONTAMINATION_MARKERS = %w[ピョン チェケラッチョ じゃりんこ ウチ あんさん 質問？ 確認？ 了解。 提案。 不明。 理解。].freeze

  def test_translator_system_prompt_is_clean
    prompt = CloudKnowledgeDb::Translator::SYSTEM_PROMPT
    CONTAMINATION_MARKERS.each do |m|
      assert_false(prompt.include?(m), "Translator SYSTEM_PROMPT contains contamination marker: #{m}")
    end
  end
end
```

- [ ] **Step 4: Run tests, verify failure**

```bash
bundle exec rake test
```

Expected: LoadError for `cloud_knowledge_db/translator`.

- [ ] **Step 5: Implement `lib/cloud_knowledge_db/translator.rb`**

```ruby
# frozen_string_literal: true

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

    MAX_TOKENS = 4096

    def initialize(client:, model_resolver:)
      @client         = client
      @model_resolver = model_resolver
    end

    # @param article_md [String]
    # @return [String] Japanese translation
    def translate(article_md)
      response = @client.messages.create(
        model:    @model_resolver.resolve(:haiku),
        system:   [{ type: 'text', text: SYSTEM_PROMPT, cache_control: { type: 'ephemeral' } }],
        messages: [{ role: 'user', content: article_md }],
        max_tokens: MAX_TOKENS
      )
      response.content.first.text
    end
  end
end
```

- [ ] **Step 6: Run tests, verify pass**

```bash
bundle exec rake test
```

Expected: 4 translator tests + 1 contamination test pass.

- [ ] **Step 7: Commit**

```bash
git add lib/cloud_knowledge_db/translator.rb test/support/fake_anthropic_client.rb test/test_translator.rb test/test_contamination.rb
git commit -m "feat: add Translator with English-only system prompt and contamination guard"
```

---

## Task 13: DailySummarizer (Opus)

**Files:**
- Create: `lib/cloud_knowledge_db/daily_summarizer.rb`
- Create: `test/test_daily_summarizer.rb`
- Modify: `test/test_contamination.rb` (add coverage for DailySummarizer)

- [ ] **Step 1: Write failing test `test/test_daily_summarizer.rb`**

```ruby
# frozen_string_literal: true
require_relative 'test_helper'
require_relative 'support/fake_anthropic_client'
require 'cloud_knowledge_db/daily_summarizer'

class DailySummarizerTest < Test::Unit::TestCase
  class FixedResolver
    def resolve(family); "claude-#{family}-fixture"; end
  end

  def setup
    @client = FakeAnthropicClient.new(responses: ["# 2026-04-15 AWS まとめ\n\n- 記事1\n- 記事2"])
    @summarizer = CloudKnowledgeDb::DailySummarizer.new(client: @client, model_resolver: FixedResolver.new)
  end

  def test_summarize_returns_markdown
    md = @summarizer.summarize(
      provider_short: 'aws',
      date: '2026-04-15',
      translated_articles: [
        { title: 'Article 1', url: 'https://x', body_ja: '本文1' },
        { title: 'Article 2', url: 'https://y', body_ja: '本文2' }
      ]
    )
    assert_match(/# 2026-04-15 AWS まとめ/, md)
  end

  def test_uses_opus_model_id
    @summarizer.summarize(provider_short: 'aws', date: '2026-04-15', translated_articles: [])
    assert_equal 'claude-opus-fixture', @client.calls.first[:model]
  end

  def test_user_message_includes_each_article
    @summarizer.summarize(
      provider_short: 'aws',
      date: '2026-04-15',
      translated_articles: [{ title: 'T1', url: 'U1', body_ja: 'B1' }]
    )
    user_content = @client.calls.first[:messages].first[:content]
    assert_match(/T1/,  user_content)
    assert_match(/U1/,  user_content)
    assert_match(/B1/,  user_content)
  end
end
```

- [ ] **Step 2: Add DailySummarizer to `test/test_contamination.rb`**

After the existing `test_translator_system_prompt_is_clean`, append:

```ruby
  def test_daily_summarizer_system_prompt_is_clean
    require 'cloud_knowledge_db/daily_summarizer'
    prompt = CloudKnowledgeDb::DailySummarizer::SYSTEM_PROMPT
    CONTAMINATION_MARKERS.each do |m|
      assert_false(prompt.include?(m), "DailySummarizer SYSTEM_PROMPT contains contamination marker: #{m}")
    end
  end
```

- [ ] **Step 3: Run tests to verify failure.**

- [ ] **Step 4: Implement `lib/cloud_knowledge_db/daily_summarizer.rb`**

```ruby
# frozen_string_literal: true

module CloudKnowledgeDb
  class DailySummarizer
    SYSTEM_PROMPT = <<~JA.freeze
      あなたはクラウドプラットフォームの公式技術ブログ新着記事をまとめるテクニカルライターです。
      与えられた1日分の翻訳済み記事リストから、以下の構造のMarkdown記事を作成してください。
      規則:
        - 見出しは「# YYYY-MM-DD <PROVIDER> まとめ」とする。
        - 各記事は「## <タイトル>」の見出し配下に、要点3つ以内の箇条書き、最後にリンクを付ける。
        - 文体は技術文書として中立な「です/ます」調。スラング・方言・絵文字・装飾語尾は禁止。
        - 出力は本文Markdownのみ。前置きや結語は不要。
    JA

    MAX_TOKENS = 4096

    def initialize(client:, model_resolver:)
      @client         = client
      @model_resolver = model_resolver
    end

    # @param provider_short [String] e.g. "aws", "gcp"
    # @param date [String] YYYY-MM-DD
    # @param translated_articles [Array<Hash>] each: {title:, url:, body_ja:}
    # @return [String] Markdown article body
    def summarize(provider_short:, date:, translated_articles:)
      user_content = build_user_content(provider_short, date, translated_articles)
      response = @client.messages.create(
        model:    @model_resolver.resolve(:opus),
        system:   [{ type: 'text', text: SYSTEM_PROMPT, cache_control: { type: 'ephemeral' } }],
        messages: [{ role: 'user', content: user_content }],
        max_tokens: MAX_TOKENS
      )
      response.content.first.text
    end

    private

    def build_user_content(provider_short, date, articles)
      header = "PROVIDER: #{provider_short.upcase}\nDATE: #{date}\n\n"
      body   = articles.map { |a| "TITLE: #{a[:title]}\nURL: #{a[:url]}\nBODY:\n#{a[:body_ja]}\n" }.join("\n---\n")
      header + body
    end
  end
end
```

- [ ] **Step 5: Run tests, verify pass.**

- [ ] **Step 6: Commit**

```bash
git add lib/cloud_knowledge_db/daily_summarizer.rb test/test_daily_summarizer.rb test/test_contamination.rb
git commit -m "feat: add DailySummarizer (Opus) with neutral Japanese system prompt"
```

---

## Task 14: ContentClassifier (Haiku, classmethod tag normalization)

**Files:**
- Create: `lib/cloud_knowledge_db/content_classifier.rb`
- Create: `test/test_content_classifier.rb`

- [ ] **Step 1: Write failing test**

```ruby
# frozen_string_literal: true
require_relative 'test_helper'
require_relative 'support/fake_anthropic_client'
require 'cloud_knowledge_db/content_classifier'

class ContentClassifierTest < Test::Unit::TestCase
  class FixedResolver
    def resolve(_); 'claude-haiku-fixture'; end
  end

  def setup
    @client = FakeAnthropicClient.new(responses: ['aws'])
    @classifier = CloudKnowledgeDb::ContentClassifier.new(client: @client, model_resolver: FixedResolver.new)
  end

  def test_classify_returns_normalized_provider_label
    label = @classifier.classify(title: 'Lambda新機能', body: '本文', tags: ['AWS', 'Lambda'])
    assert_equal 'aws', label
  end

  def test_uses_haiku_model
    @classifier.classify(title: 't', body: 'b', tags: [])
    assert_equal 'claude-haiku-fixture', @client.calls.first[:model]
  end
end
```

- [ ] **Step 2: Run, verify failure.**

- [ ] **Step 3: Implement `lib/cloud_knowledge_db/content_classifier.rb`**

```ruby
# frozen_string_literal: true

module CloudKnowledgeDb
  class ContentClassifier
    SYSTEM_PROMPT = <<~EN.freeze
      You classify a Japanese cloud-tech blog article into exactly ONE of: aws, gcp, gws, gitlab, none.
      Output the single lowercase label only. No explanation, no punctuation.
    EN

    LABELS = %w[aws gcp gws gitlab none].freeze
    MAX_TOKENS = 8

    def initialize(client:, model_resolver:)
      @client         = client
      @model_resolver = model_resolver
    end

    # @return [String] one of LABELS
    def classify(title:, body:, tags:)
      content = "TITLE: #{title}\nTAGS: #{tags.join(', ')}\nBODY: #{body[0, 800]}"
      response = @client.messages.create(
        model:    @model_resolver.resolve(:haiku),
        system:   [{ type: 'text', text: SYSTEM_PROMPT, cache_control: { type: 'ephemeral' } }],
        messages: [{ role: 'user', content: content }],
        max_tokens: MAX_TOKENS
      )
      raw = response.content.first.text.strip.downcase
      LABELS.include?(raw) ? raw : 'none'
    end
  end
end
```

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5: Commit**

```bash
git add lib/cloud_knowledge_db/content_classifier.rb test/test_content_classifier.rb
git commit -m "feat: add ContentClassifier (Haiku) with strict label whitelist"
```

---

## Task 15: EsaWriter (port from ruby-knowledge-db)

**Files:**
- Create: `lib/cloud_knowledge_db/esa_writer.rb`
- Create: `test/test_esa_writer.rb`

- [ ] **Step 1: Write failing test**

```ruby
# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/esa_writer'

class EsaWriterTest < Test::Unit::TestCase
  def test_initializer_stores_team_category_wip
    w = CloudKnowledgeDb::EsaWriter.new(team: 'bist', category: 'test/x', wip: true)
    assert_equal 'bist',   w.team
    assert_equal 'test/x', w.category
    assert_true w.wip
  end
end
```

- [ ] **Step 2: Run, verify failure.**

- [ ] **Step 3: Implement `lib/cloud_knowledge_db/esa_writer.rb`** (ported, with attr_readers added for testability):

```ruby
# frozen_string_literal: true
require 'net/http'
require 'uri'
require 'json'

module CloudKnowledgeDb
  class EsaWriter
    RATE_WAIT = 2

    attr_reader :team, :category, :wip

    def initialize(team:, category:, wip:)
      @team     = team
      @category = category
      @wip      = wip
    end

    # @param name     [String]
    # @param body_md  [String]
    # @return [Hash] esa API response
    def post(name:, body_md:)
      token = fetch_token
      uri   = URI("https://api.esa.io/v1/teams/#{@team}/posts")

      http         = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      req = Net::HTTP::Post.new(uri.path)
      req['Authorization'] = "Bearer #{token}"
      req['Content-Type']  = 'application/json'
      req.body = JSON.generate({
        post: { name: name, body_md: body_md, category: @category, wip: @wip }
      })

      res  = http.request(req)
      body = JSON.parse(res.body)

      sleep RATE_WAIT
      body
    ensure
      token = nil
    end

    private

    def fetch_token
      token = `/usr/bin/security find-generic-password -s 'esa-mcp-token' -w 2>/dev/null`.strip
      abort "ESA token not found in keychain (key: esa-mcp-token)" if token.empty?
      token
    end
  end
end
```

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5: Commit**

```bash
git add lib/cloud_knowledge_db/esa_writer.rb test/test_esa_writer.rb
git commit -m "feat: add EsaWriter (ported from ruby-knowledge-db, attr_readers added)"
```

---

# Phase D — Pipeline (cloud-knowledge-db repo)

## Task 16: Expand `config/sources.yml` to all 5 sources

**Files:**
- Modify: `config/sources.yml`
- Modify: `config/environments/{development,test,production}.yml` (add per-source category entries)

- [ ] **Step 1: Replace `config/sources.yml`**

```yaml
sources:
  aws_blog:
    short_name: aws
    feed_url: https://aws.amazon.com/blogs/aws/feed/
    adapter: rss
    source_article: aws/blogs/news
    source_original: aws/blogs/news/original

  gcp_blog:
    short_name: gcp
    feed_url: https://cloud.google.com/blog/products/gcp/rss
    adapter: rss
    source_article: gcp/blogs/products
    source_original: gcp/blogs/products/original

  gws_blog:
    short_name: gws
    feed_url: https://workspace.google.com/blog/rss
    adapter: rss
    source_article: gws/blogs/all
    source_original: gws/blogs/all/original

  gitlab_blog:
    short_name: gitlab
    feed_url: https://about.gitlab.com/atom.xml
    adapter: rss
    source_article: gitlab/blogs/all
    source_original: gitlab/blogs/all/original

  classmethod_blog:
    short_name: classmethod
    feed_url: https://dev.classmethod.jp/feed/
    adapter: classmethod
    tag_to_source:
      AWS:          aws/classmethod
      "Google Cloud": gcp/classmethod
      Workspace:    gws/classmethod
      GitLab:       gitlab/classmethod
```

- [ ] **Step 2: Update `config/environments/test.yml` esa.sources to include all 4 official sources** (classmethod intentionally absent — esa-skipped):

```yaml
db_path: db/cloud_knowledge_test.db

esa:
  team: bist
  wip: true
  sources:
    aws_blog:    { category: test/cloud-trunk-changes/aws }
    gcp_blog:    { category: test/cloud-trunk-changes/gcp }
    gws_blog:    { category: test/cloud-trunk-changes/gws }
    gitlab_blog: { category: test/cloud-trunk-changes/gitlab }

models:
  translator:       haiku
  classifier:       haiku
  daily_summarizer: haiku
  default:          haiku
```

- [ ] **Step 3: Repeat the structure for `development.yml` and `production.yml`** (use the corresponding env_prefix and team/wip from spec section 11).

- [ ] **Step 4: Run existing tests to confirm nothing breaks**

```bash
bundle exec rake test
```

Expected: still passing.

- [ ] **Step 5: Commit**

```bash
git add config/
git commit -m "feat: define 5 blog sources (4 official + classmethod) and per-env esa categories"
```

---

## Task 17: Rake helpers + `fetch:<source_key>` task

**Files:**
- Modify: `Rakefile`

- [ ] **Step 1: Replace `Rakefile` with the full version below**

```ruby
# frozen_string_literal: true
require 'rake/testtask'
require_relative 'lib/cloud_knowledge_db/config'
require_relative 'lib/cloud_knowledge_db/trunk_bookmark'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.test_files = FileList['test/test_*.rb']
  t.verbose = true
end

task default: :test

LAST_RUN_PATH = File.expand_path('db/last_run.yml', __dir__)
TB            = CloudKnowledgeDb::TrunkBookmark

def cfg; @cfg ||= CloudKnowledgeDb::Config.load; end
def source_keys; cfg['sources'].keys; end

def write_md(dir, fname, frontmatter, body)
  fm_yaml = frontmatter.transform_keys(&:to_s).to_yaml.sub(/^---\n/, '')
  File.write(File.join(dir, fname), "---\n#{fm_yaml}---\n#{body}\n")
end

def parse_md(path)
  raw = File.read(path, encoding: 'utf-8')
  return nil unless raw.start_with?('---')
  parts = raw.split(/^---\s*$/, 3)
  return nil if parts.length < 3
  fm   = YAML.safe_load(parts[1], permitted_classes: [Date, Time]) || {}
  body = parts[2].strip
  return nil if body.empty?
  [fm, body]
end

def slug_for(url)
  return Digest::SHA256.hexdigest('')[0, 8] if url.nil? || url.empty?
  tail = URI.parse(url).path.split('/').reject(&:empty?).last || ''
  tail.empty? ? Digest::SHA256.hexdigest(url)[0, 8] : tail
end

# ------ fetch:<source_key> ------

source_keys_via_yaml = (CloudKnowledgeDb::Config.load['sources'].keys rescue [])

namespace :fetch do
  source_keys_via_yaml.each do |key|
    desc "fetch source=#{key} for [SINCE, BEFORE) window. Outputs DIR=tmpdir."
    task key.to_sym do
      require 'bundler/setup'
      require 'date'
      require 'time'
      require 'tmpdir'
      require 'fileutils'
      require 'yaml'
      require 'digest'
      require 'uri'
      require 'cloud_blog_collector'

      CloudKnowledgeDb::Config.ensure_write_host!
      since  = ENV['SINCE']  ? Time.parse(ENV['SINCE'])  : nil
      before = ENV['BEFORE'] ? Time.parse(ENV['BEFORE']) : Time.now

      sources = CloudKnowledgeDb::Config.load['sources']
      src_cfg = sources[key] or abort "unknown source key: #{key}"

      collector = CloudBlogCollector::Collector.new(src_cfg)
      records   = collector.fetch(since: since, before: before)

      dir = Dir.mktmpdir("cloudkb_#{key}_#{(since || 'epoch').to_s.tr(' :','_-')}_#{before.to_s.tr(' :','_-')}_")
      records.each do |r|
        date  = r[:published_at].to_date.to_s
        slug  = slug_for(r[:url])
        fname = "#{date}-#{src_cfg['short_name']}-original-#{slug}.md"
        write_md(dir, fname, {
          source:       r[:source],
          url:          r[:url],
          title:        r[:title],
          published_at: r[:published_at].iso8601,
          date:         date,
          type:         'original'
        }, r[:content_original].to_s)
      end

      puts "Generated #{records.length} records"
      puts "DIR=#{dir}"
    end
  end
end
```

- [ ] **Step 2: Smoke test fetch task with classmethod fixture-style source**

(For now, run with no real network expectation — just verify task is registered.)

```bash
bundle exec rake -T fetch
```

Expected: 5 fetch:* tasks listed (aws_blog, gcp_blog, gws_blog, gitlab_blog, classmethod_blog).

- [ ] **Step 3: Commit**

```bash
git add Rakefile
git commit -m "feat: add fetch:<source_key> Rake tasks generated from sources.yml"
```

---

## Task 18: `translate:<source_key>` Rake task

**Files:**
- Modify: `Rakefile`

- [ ] **Step 1: Append translate namespace to `Rakefile`**

Add after the `namespace :fetch` block:

```ruby
namespace :translate do
  source_keys_via_yaml.each do |key|
    desc "translate fetched MDs in DIR for source=#{key}"
    task key.to_sym do
      require 'bundler/setup'
      require 'fileutils'
      require 'yaml'
      require 'anthropic'
      require_relative 'lib/cloud_knowledge_db/translator'
      require_relative 'lib/cloud_knowledge_db/model_resolver'

      CloudKnowledgeDb::Config.ensure_write_host!
      dir = ENV['DIR'] or abort 'DIR is required'
      src_cfg = CloudKnowledgeDb::Config.load['sources'][key] or abort "unknown source: #{key}"
      next if src_cfg['adapter'] == 'classmethod'  # classmethod は日本語原文、翻訳スキップ

      client     = ::Anthropic::Client.new
      resolver   = CloudKnowledgeDb::ModelResolver.new(client: client)
      translator = CloudKnowledgeDb::Translator.new(client: client, model_resolver: resolver)

      Dir.glob(File.join(dir, "*-#{src_cfg['short_name']}-original-*.md")).each do |orig_path|
        ja_path = orig_path.sub('-original-', '-')
        next if File.exist?(ja_path)

        fm, body = parse_md(orig_path)
        next if fm.nil? || body.nil?

        puts "translate: #{File.basename(orig_path)}"
        ja_body = translator.translate(body)

        ja_fm = fm.merge(
          'source'        => src_cfg['source_article'],
          'type'          => 'article',
          'translated_at' => Time.now.iso8601,
          'origin_url'    => fm['url']
        )
        write_md(dir, File.basename(ja_path), ja_fm, ja_body)
      end
    end
  end
end
```

- [ ] **Step 2: List rake tasks to verify registration**

```bash
bundle exec rake -T translate
```

Expected: 5 translate:* tasks listed.

- [ ] **Step 3: Commit**

```bash
git add Rakefile
git commit -m "feat: add translate:<source_key> task using Translator (Haiku)"
```

---

## Task 19: `import:<source_key>` Rake task (ruby-knowledge-store integration)

**Files:**
- Modify: `Rakefile`

- [ ] **Step 1: Append import namespace to `Rakefile`**

```ruby
def build_store(cfg)
  CloudKnowledgeDb::Config.ensure_write_host!
  db = File.expand_path(cfg['db_path'], __dir__)
  RubyKnowledgeStore::Migrator.new(db, migrations_dir: RubyKnowledgeStore::MIGRATIONS_DIR).run
  RubyKnowledgeStore::Store.new(db, embedder: RubyKnowledgeStore::Embedder.new)
end

namespace :import do
  source_keys_via_yaml.each do |key|
    desc "import MDs in DIR for source=#{key} (both original and translated)"
    task key.to_sym do
      require 'bundler/setup'
      require 'ruby_knowledge_store'

      dir = ENV['DIR'] or abort 'DIR is required'
      src_cfg = CloudKnowledgeDb::Config.load['sources'][key] or abort "unknown source: #{key}"
      pattern = "*-#{src_cfg['short_name']}-*.md"

      store = build_store(CloudKnowledgeDb::Config.load)
      stored, skipped = 0, 0

      Dir.glob(File.join(dir, pattern)).each do |path|
        fm, body = parse_md(path)
        next if fm.nil? || body.nil?
        if store.store(content: body, source: fm['source'])
          stored += 1
        else
          skipped += 1
        end
      end

      puts "import #{key}: stored=#{stored}, skipped=#{skipped}"
    end
  end
end
```

> NOTE: `RubyKnowledgeStore::Store#store` should return truthy when a row was inserted, falsy when content_hash collision skipped it. If the actual API differs, adapt the wrapper. Verify by inspecting `../ruby-knowledge-store/lib/ruby_knowledge_store/store.rb` before running.

- [ ] **Step 2: Verify store API matches** by reading `../ruby-knowledge-store/lib/ruby_knowledge_store/store.rb` and adjusting the call if `store(content:, source:)` is named differently (e.g., `import` or `add`). Update the Rakefile accordingly.

- [ ] **Step 3: Verify task registration**

```bash
bundle exec rake -T import
```

- [ ] **Step 4: Commit**

```bash
git add Rakefile
git commit -m "feat: add import:<source_key> task via ruby-knowledge-store"
```

---

## Task 20: `esa:<source_key>` Rake task

**Files:**
- Modify: `Rakefile`

- [ ] **Step 1: Append esa namespace to `Rakefile`**

```ruby
namespace :esa do
  source_keys_via_yaml.each do |key|
    desc "post DailySummarizer-generated article for source=#{key} from MDs in DIR"
    task key.to_sym do
      require 'bundler/setup'
      require 'anthropic'
      require_relative 'lib/cloud_knowledge_db/esa_writer'
      require_relative 'lib/cloud_knowledge_db/daily_summarizer'
      require_relative 'lib/cloud_knowledge_db/model_resolver'

      CloudKnowledgeDb::Config.ensure_write_host!
      dir   = ENV['DIR'] or abort 'DIR is required'
      cfg   = CloudKnowledgeDb::Config.load
      src   = cfg['sources'][key] or abort "unknown source: #{key}"

      # classmethod は esa 投稿対象外（spec Q4=B）
      if src['adapter'] == 'classmethod'
        puts "esa #{key}: skipped (classmethod is DB-only)"
        next
      end

      esa_cfg = cfg.dig('esa', 'sources', key) or abort "no esa.sources.#{key} in env yml"
      writer  = CloudKnowledgeDb::EsaWriter.new(
        team:     cfg['esa']['team'],
        category: esa_cfg['category'],
        wip:      cfg['esa']['wip']
      )

      client     = ::Anthropic::Client.new
      resolver   = CloudKnowledgeDb::ModelResolver.new(client: client)
      summarizer = CloudKnowledgeDb::DailySummarizer.new(client: client, model_resolver: resolver)

      # Group translated MDs by date
      ja_paths = Dir.glob(File.join(dir, "*-#{src['short_name']}-*.md"))
                    .reject { |p| File.basename(p).include?('-original-') }
      grouped  = ja_paths.group_by do |p|
        File.basename(p)[/^\d{4}-\d{2}-\d{2}/]
      end

      grouped.each do |date, paths|
        next if date.nil?
        articles = paths.map do |p|
          fm, body = parse_md(p)
          { title: fm['title'], url: fm['origin_url'] || fm['url'], body_ja: body }
        end
        next if articles.empty?

        body_md = summarizer.summarize(provider_short: src['short_name'], date: date, translated_articles: articles)
        full_path = "#{esa_cfg['category']}/#{date.tr('-','/')}/#{date}-#{src['short_name']}-cloud-changes"
        result = writer.post(name: full_path, body_md: body_md)
        puts "Posted: ##{result['number']} #{result['full_name']}" if result['number']
      end
    end
  end
end
```

- [ ] **Step 2: Verify task registration**

```bash
bundle exec rake -T esa
```

- [ ] **Step 3: Commit**

```bash
git add Rakefile
git commit -m "feat: add esa:<source_key> task that posts DailySummarizer output"
```

---

## Task 21: `daily` Rake task (orchestrator)

**Files:**
- Modify: `Rakefile`

- [ ] **Step 1: Append `daily` task to `Rakefile`**

```ruby
desc 'Run the full daily pipeline (fetch -> translate -> import -> esa) across all sources'
task :daily do
  require 'bundler/setup'
  require 'date'
  require 'time'

  CloudKnowledgeDb::Config.ensure_write_host!
  cfg = CloudKnowledgeDb::Config.load
  keys = cfg['sources'].keys

  before = ENV['BEFORE'] ? Date.parse(ENV['BEFORE']) : Date.today
  since  = ENV['SINCE']  ? Date.parse(ENV['SINCE'])  : (before - 1)

  data = TB.load(LAST_RUN_PATH)

  keys.each do |key|
    puts "==== #{key} (#{since}..#{before}) ===="
    data = TB.mark_started(data, key, before: before, at: Time.now)
    TB.save(LAST_RUN_PATH, data)

    ENV['SINCE']  = since.iso8601
    ENV['BEFORE'] = before.iso8601
    Rake::Task["fetch:#{key}"].invoke
    dir = `bundle exec rake fetch:#{key} 2>&1 | grep '^DIR='`.split('=', 2).last&.strip
    next if dir.nil? || dir.empty?

    ENV['DIR'] = dir
    Rake::Task["translate:#{key}"].invoke
    Rake::Task["import:#{key}"].invoke
    Rake::Task["esa:#{key}"].invoke

    data = TB.mark_completed(data, key, before: before, at: Time.now,
      models_used: { translator: 'haiku', daily_summarizer: cfg['models']['daily_summarizer'] })
    TB.save(LAST_RUN_PATH, data)
  end
end
```

> NOTE: The double-invoke pattern for fetch (once via Rake task graph, once via shell to capture DIR) is awkward. Refactor to a shared method that returns DIR — but for plan correctness keep it explicit until the task is green. Acceptable refactor: extract `do_fetch(key, since, before) -> dir` helper that fetch:<key> wraps and daily calls directly.

- [ ] **Step 2: Refactor: extract `do_fetch(key, since:, before:)` helper that returns DIR**

Replace the inner block of `fetch:<key>` and the body of `daily` to call this shared helper rather than reinvoking the Rake task. Implementation:

```ruby
def do_fetch(key, since:, before:)
  src_cfg = CloudKnowledgeDb::Config.load['sources'][key] or abort "unknown source: #{key}"
  collector = CloudBlogCollector::Collector.new(src_cfg)
  records   = collector.fetch(since: since, before: before)

  dir = Dir.mktmpdir("cloudkb_#{key}_")
  records.each do |r|
    date  = r[:published_at].to_date.to_s
    slug  = slug_for(r[:url])
    fname = "#{date}-#{src_cfg['short_name']}-original-#{slug}.md"
    write_md(dir, fname, {
      source: r[:source], url: r[:url], title: r[:title],
      published_at: r[:published_at].iso8601, date: date, type: 'original'
    }, r[:content_original].to_s)
  end
  puts "fetch #{key}: #{records.length} records -> #{dir}"
  dir
end
```

Then in `daily`:

```ruby
dir = do_fetch(key, since: since.to_time, before: before.to_time)
ENV['DIR'] = dir
Rake::Task["translate:#{key}"].invoke
Rake::Task["import:#{key}"].invoke
Rake::Task["esa:#{key}"].invoke
Rake::Task["translate:#{key}"].reenable
Rake::Task["import:#{key}"].reenable
Rake::Task["esa:#{key}"].reenable
```

- [ ] **Step 3: Smoke test (test env, no real network — expect bundler success at least)**

```bash
APP_ENV=test bundle exec rake -T daily
```

Expected: `daily` task listed.

- [ ] **Step 4: Commit**

```bash
git add Rakefile
git commit -m "feat: add daily orchestrator wired through helpers and twin-stage bookmark"
```

---

# Phase E — Operations / observability

## Task 22: `db:scan_pollution` and `db:scan_contamination`

**Files:**
- Modify: `Rakefile`

- [ ] **Step 1: Append db namespace to Rakefile**

```ruby
namespace :db do
  desc 'Scan memories for pollution markers (empty meta, dup heads)'
  task :scan_pollution do
    require 'bundler/setup'
    require 'ruby_knowledge_store'
    require 'sqlite3'
    require 'sqlite_vec'

    cfg = CloudKnowledgeDb::Config.load
    db_path = File.expand_path(cfg['db_path'], __dir__)
    db = SQLite3::Database.new(db_path)
    db.enable_load_extension(true)
    SqliteVec.load(db)

    markers = ['翻訳できません', '出力フォーマット', 'no content', '本文がありません', '空']
    bad_ids = []
    markers.each do |m|
      rows = db.execute('SELECT id, source FROM memories WHERE content LIKE ?', ["%#{m}%"])
      rows.each { |id, src| puts "marker[#{m}] id=#{id} source=#{src}"; bad_ids << id }
    end

    puts "----"
    dup = db.execute(<<~SQL)
      SELECT source, substr(content,1,200), GROUP_CONCAT(id), COUNT(*) c
        FROM memories
       GROUP BY source, substr(content,1,200)
      HAVING c > 1
    SQL
    dup.each { |s, head, ids, c| puts "dup source=#{s} count=#{c} ids=#{ids}" }

    puts "Found #{bad_ids.uniq.length} polluted ids"
  end

  desc 'Scan memories for CLAUDE.md contamination markers'
  task :scan_contamination do
    require 'bundler/setup'
    require 'sqlite3'

    cfg = CloudKnowledgeDb::Config.load
    db_path = File.expand_path(cfg['db_path'], __dir__)
    db = SQLite3::Database.new(db_path)

    markers = %w[ピョン チェケラッチョ じゃりんこ ウチ あんさん 質問？ 確認？ 了解。 提案。 不明。 理解。]
    hits = []
    markers.each do |m|
      rows = db.execute('SELECT id, source FROM memories WHERE content LIKE ?', ["%#{m}%"])
      rows.each { |id, src| puts "contam[#{m}] id=#{id} source=#{src}"; hits << id }
    end
    puts "Found #{hits.uniq.length} contaminated ids"
  end
end
```

- [ ] **Step 2: Verify task registration**

```bash
bundle exec rake -T db
```

- [ ] **Step 3: Commit**

```bash
git add Rakefile
git commit -m "feat: add db:scan_pollution and db:scan_contamination read-only audits"
```

---

## Task 23: `db:delete_polluted` (host-guarded, IDS-required)

**Files:**
- Modify: `Rakefile`

- [ ] **Step 1: Append to db namespace**

```ruby
  desc 'DESTRUCTIVE delete by IDS=1,2,3 (host_guard enforced)'
  task :delete_polluted do
    require 'bundler/setup'
    require 'sqlite3'
    require 'sqlite_vec'

    CloudKnowledgeDb::Config.ensure_write_host!
    ids = (ENV['IDS'] || '').split(',').map { |s| Integer(s.strip) }
    abort 'IDS is required (e.g. IDS=1,2,3)' if ids.empty?

    cfg = CloudKnowledgeDb::Config.load
    db_path = File.expand_path(cfg['db_path'], __dir__)
    db = SQLite3::Database.new(db_path)
    db.enable_load_extension(true)
    SqliteVec.load(db)

    placeholders = (['?'] * ids.length).join(',')
    db.transaction
    db.execute("DELETE FROM memories_vec WHERE memory_id IN (#{placeholders})", ids)
    db.execute("DELETE FROM memories     WHERE id        IN (#{placeholders})", ids)
    db.commit
    puts "Deleted #{ids.length} ids"
  end
```

- [ ] **Step 2: Commit**

```bash
git add Rakefile
git commit -m "feat: add db:delete_polluted IDS=... destructive task with host guard"
```

---

## Task 24: `esa:find_duplicates` and `esa:delete`

**Files:**
- Modify: `Rakefile`

- [ ] **Step 1: Append to esa namespace**

```ruby
namespace :esa do
  desc 'Find duplicate posts (same base name, optional DATE=YYYY-MM-DD)'
  task :find_duplicates do
    require 'bundler/setup'
    require 'net/http'
    require 'uri'
    require 'json'

    cfg = CloudKnowledgeDb::Config.load
    team = cfg['esa']['team']
    date = ENV['DATE']

    token = `/usr/bin/security find-generic-password -s 'esa-mcp-token' -w 2>/dev/null`.strip
    abort 'esa token missing' if token.empty?

    q = ["category:cloud-trunk-changes"]
    q << "created:#{date}" if date
    uri = URI("https://api.esa.io/v1/teams/#{team}/posts?q=#{URI.encode_www_form_component(q.join(' '))}&per_page=100")
    req = Net::HTTP::Get.new(uri.request_uri)
    req['Authorization'] = "Bearer #{token}"
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
    data = JSON.parse(res.body)

    by_base = (data['posts'] || []).group_by { |p| p['name'].sub(/ \(\d+\)$/, '') }
    by_base.each do |name, posts|
      next unless posts.length > 1
      puts "DUP base=#{name} count=#{posts.length}"
      posts.each { |p| puts "  ##{p['number']} #{p['name']} #{p['full_name']}" }
    end
  end

  desc 'DESTRUCTIVE delete esa posts by IDS=104,110 (host_guard enforced)'
  task :delete do
    CloudKnowledgeDb::Config.ensure_write_host!
    require 'net/http'
    require 'uri'

    ids = (ENV['IDS'] || '').split(',').map { |s| Integer(s.strip) }
    abort 'IDS is required (e.g. IDS=104,110)' if ids.empty?
    cfg = CloudKnowledgeDb::Config.load
    team = cfg['esa']['team']
    token = `/usr/bin/security find-generic-password -s 'esa-mcp-token' -w 2>/dev/null`.strip

    ids.each do |id|
      uri = URI("https://api.esa.io/v1/teams/#{team}/posts/#{id}")
      req = Net::HTTP::Delete.new(uri.request_uri)
      req['Authorization'] = "Bearer #{token}"
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
      puts "DELETE ##{id} -> #{res.code}"
      sleep 2
    end
  end
end
```

- [ ] **Step 2: Verify task registration**

```bash
bundle exec rake -T esa
```

- [ ] **Step 3: Commit**

```bash
git add Rakefile
git commit -m "feat: add esa:find_duplicates and esa:delete operations tasks"
```

---

## Task 25: `smoke:rss_endpoints`

**Files:**
- Modify: `Rakefile`

- [ ] **Step 1: Append smoke namespace**

```ruby
namespace :smoke do
  desc 'HEAD-check all configured feed_url / index_url endpoints (no LLM)'
  task :rss_endpoints do
    require 'bundler/setup'
    require 'net/http'
    require 'uri'

    cfg = CloudKnowledgeDb::Config.load
    cfg['sources'].each do |key, src|
      url = src['feed_url'] || src['index_url']
      next unless url
      uri = URI(url)
      req = Net::HTTP::Head.new(uri.request_uri)
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') { |h| h.request(req) }
      puts "#{key}\t#{res.code}\t#{url}"
    end
  end
end
```

- [ ] **Step 2: Run smoke task** (real network)

```bash
bundle exec rake smoke:rss_endpoints
```

Expected: 5 lines, all `200` codes (or document any 3xx redirects to follow up).

- [ ] **Step 3: Commit**

```bash
git add Rakefile
git commit -m "feat: add smoke:rss_endpoints HEAD-check task"
```

---

# Phase F — Subagents (project-private)

## Task 26: `cloud-knowledge-db-daily` subagent

**Files:**
- Create: `.claude/agents/cloud-knowledge-db-daily.md`
- Create: `.claude/commands/cloud-knowledge-db-daily.md`

- [ ] **Step 1: Create `.claude/agents/cloud-knowledge-db-daily.md`**

```markdown
---
name: cloud-knowledge-db-daily
description: Daily ingestion orchestrator for cloud-knowledge-db. Loads bookmark, runs PLAN, gates on CONFIRMED token, executes rake daily, runs post-checks (scan_pollution / scan_contamination / esa:find_duplicates).
model: sonnet
tools: Bash, Read
---

You are the daily-ingestion orchestrator for the cloud-knowledge-db project. You operate in two modes: PLAN and EXECUTE.

## PLAN mode (default — when invoked with no CONFIRMED token)

1. Read `db/last_run.yml` (yaml). For each `*_blog` source key (aws_blog, gcp_blog, gws_blog, gitlab_blog, classmethod_blog):
   - Capture `last_started_before` and `last_completed_before`
   - WIP = (started > completed) OR (completed missing while started present)
2. FLOOR = min(last_completed_before across all sources). If any source has no completion, FLOOR = "never".
3. Recommended SINCE/BEFORE:
   - SINCE = FLOOR (or yesterday if FLOOR is "never")
   - BEFORE = today
4. For each source, run a HEAD check on its `feed_url` / `index_url` from `config/sources.yml` to confirm liveness.
5. Output a report:
   - For each source: bookmark snapshot, WIP flag, endpoint status code
   - Recommended CONFIRMED token: `CONFIRMED SINCE=YYYY-MM-DD BEFORE=YYYY-MM-DD`

Then STOP. Do not invoke any rake tasks until re-dispatched with the CONFIRMED token.

## EXECUTE mode (when invoked with `CONFIRMED SINCE=... BEFORE=...` token)

1. `APP_ENV=production bundle exec rake daily SINCE=<since> BEFORE=<before>`
2. `APP_ENV=production bundle exec rake db:scan_pollution`
3. `APP_ENV=production bundle exec rake db:scan_contamination`
4. `APP_ENV=production bundle exec rake esa:find_duplicates DATE=<since>`
5. Report: per-source completion status, polluted/contaminated ID counts, duplicate posts found.

If any of the post-checks return non-zero IDs, recommend dispatching `cloud-knowledge-db-pollution-triage` for triage.

## Constraints

- Never invoke `db:delete_polluted` or `esa:delete` without explicit user approval.
- Never bypass host_guard with ALLOW_WRITE=1.
- Never edit code or config files.
```

- [ ] **Step 2: Create `.claude/commands/cloud-knowledge-db-daily.md`**

```markdown
---
description: Run cloud-knowledge-db daily ingestion (PLAN/CONFIRMED/EXECUTE). Dispatches the cloud-knowledge-db-daily subagent.
---

Dispatch the `cloud-knowledge-db-daily` subagent in PLAN mode. After receiving the PLAN report, await user confirmation. When the user replies with `CONFIRMED SINCE=YYYY-MM-DD BEFORE=YYYY-MM-DD`, re-dispatch the same subagent in EXECUTE mode passing that token.
```

- [ ] **Step 3: Commit**

```bash
git add .claude/agents/cloud-knowledge-db-daily.md .claude/commands/cloud-knowledge-db-daily.md
git commit -m "feat: add cloud-knowledge-db-daily subagent and slash command"
```

---

## Task 27: `cloud-knowledge-db-pollution-triage` subagent

**Files:**
- Create: `.claude/agents/cloud-knowledge-db-pollution-triage.md`

- [ ] **Step 1: Create the file**

```markdown
---
name: cloud-knowledge-db-pollution-triage
description: Analyzes scan_pollution / scan_contamination output and recommends DELETE IDs. Conservative — Opus for judgment. Never executes deletion itself.
model: opus
tools: Bash, Read
---

You triage potentially-polluted memories rows in cloud_knowledge.db. You DO NOT delete anything.

## Inputs

The user pastes (or you re-run) the output of:
- `APP_ENV=production bundle exec rake db:scan_pollution`
- `APP_ENV=production bundle exec rake db:scan_contamination`

## Process

For each candidate ID:
1. Inspect the row content:
   `bundle exec ruby -r sqlite3 -e "p SQLite3::Database.new('db/cloud_knowledge.db').execute('SELECT id, source, substr(content,1,1500) FROM memories WHERE id = ?', [<ID>])"`
2. Decide: DELETE / KEEP / INSPECT-MORE.
3. Record a one-line rationale per ID.

## Output

A table:

| ID | source | verdict | rationale |
|---|---|---|---|

Followed by the suggested next command (the user runs it, not you):
- `APP_ENV=production bundle exec rake db:delete_polluted IDS=<comma-separated>`

## Constraints

- Never run `db:delete_polluted` or `esa:delete`.
- Never bypass host_guard.
- If unsure, recommend INSPECT-MORE rather than DELETE.
```

- [ ] **Step 2: Commit**

```bash
git add .claude/agents/cloud-knowledge-db-pollution-triage.md
git commit -m "feat: add cloud-knowledge-db-pollution-triage subagent (Opus, read-only)"
```

---

## Task 28: `cloud-knowledge-db-source-health` subagent

**Files:**
- Create: `.claude/agents/cloud-knowledge-db-source-health.md`

- [ ] **Step 1: Create the file**

```markdown
---
name: cloud-knowledge-db-source-health
description: Checks RSS/ATOM endpoint health and recommends adapter upgrades (RSS -> WebFetch -> Chrome) when feeds break. Weekly cadence.
model: sonnet
tools: Bash, Read, WebFetch
---

You check the health of all configured blog feeds and recommend adapter upgrades when needed.

## Process

1. Run `bundle exec rake smoke:rss_endpoints`. Capture status codes per source.
2. For any source returning non-2xx:
   - Use WebFetch on the URL to inspect what's actually served (HTML page? redirect? gone?).
   - Recommend an adapter change in `config/sources.yml`:
     - 4xx/5xx but HTML page exists → propose `adapter: web_fetch` with selector hints
     - JS-rendered (no useful HTML) → propose `adapter: chrome` (with note to implement Chrome adapter)
3. For sources returning 2xx, sanity-check that the RSS body parses (`bundle exec ruby -r rss -r open-uri -e "p RSS::Parser.parse(URI.open(ENV['URL']).read, false).items.first.title"`).

## Output

Per source:
- Status: OK / DEGRADED / DEAD
- Recommendation: KEEP / UPGRADE-TO-WEBFETCH / UPGRADE-TO-CHROME
- Suggested config diff (yaml snippet)

## Constraints

- Read-only. Never edit `config/sources.yml`.
- Never run `rake daily` or any write task.
```

- [ ] **Step 2: Commit**

```bash
git add .claude/agents/cloud-knowledge-db-source-health.md
git commit -m "feat: add cloud-knowledge-db-source-health subagent (weekly RSS audit)"
```

---

## Task 29: `.claude/settings.local.json` permissions

**Files:**
- Modify: `.claude/settings.local.json`

- [ ] **Step 1: Replace contents**

```json
{
  "permissions": {
    "allow": [
      "Bash(bundle exec rake daily*)",
      "Bash(bundle exec rake fetch:*)",
      "Bash(bundle exec rake translate:*)",
      "Bash(bundle exec rake import:*)",
      "Bash(bundle exec rake esa:*)",
      "Bash(bundle exec rake db:scan_pollution)",
      "Bash(bundle exec rake db:scan_contamination)",
      "Bash(bundle exec rake db:delete_polluted IDS=*)",
      "Bash(bundle exec rake esa:find_duplicates*)",
      "Bash(bundle exec rake esa:delete IDS=*)",
      "Bash(bundle exec rake smoke:*)",
      "Bash(bundle exec rake -T*)",
      "Bash(bundle exec ruby*)",
      "Bash(scutil --get LocalHostName)",
      "Bash(/usr/bin/security find-generic-password*)"
    ]
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add .claude/settings.local.json
git commit -m "chore: scope project permissions for cloud-knowledge-db daily flow"
```

---

# Phase G — chiebukuro-mcp integration

## Task 30: dotfiles meta_patches/cloud_knowledge.yml

**Files (in dotfiles repo):**
- Create: `~/Library/Mobile Documents/com~apple~CloudDocs/dotfiles/chiebukuro-mcp/chiebukuro-mcp/scripts/meta_patches/cloud_knowledge.yml`

- [ ] **Step 1: Create the meta_patches yaml** with content from spec section 5.2 (use the corrected version with provider-prefix source naming and the unified `recent_articles_by_provider` recipe).

- [ ] **Step 2: Verify yaml validates**

```bash
ruby -ryaml -e 'YAML.safe_load_file(ENV["F"])' F='/Users/bash/Library/Mobile Documents/com~apple~CloudDocs/dotfiles/chiebukuro-mcp/chiebukuro-mcp/scripts/meta_patches/cloud_knowledge.yml'
```

Expected: no error.

- [ ] **Step 3: Commit in dotfiles repo**

```bash
cd "/Users/bash/Library/Mobile Documents/com~apple~CloudDocs/dotfiles"
git add chiebukuro-mcp/chiebukuro-mcp/scripts/meta_patches/cloud_knowledge.yml
git commit -m "feat(meta): add cloud_knowledge meta_patches (recipes + clarification_fields)"
cd -
```

---

## Task 31: chiebukuro.json + apply meta

**Files:**
- Modify: `~/chiebukuro-mcp/chiebukuro.json`
- Run: `apply_meta_patches.rb` for cloud_knowledge

- [ ] **Step 1: Add cloud_knowledge entry to `~/chiebukuro-mcp/chiebukuro.json`**

Add this entry inside `databases` (preserve existing entries):

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

- [ ] **Step 2: Apply meta_patches**

(Locate `apply_meta_patches.rb` under the dotfiles chiebukuro-mcp scripts dir.)

```bash
cd "/Users/bash/Library/Mobile Documents/com~apple~CloudDocs/dotfiles/chiebukuro-mcp/chiebukuro-mcp/scripts"
bundle exec ruby apply_meta_patches.rb cloud_knowledge
cd -
```

Expected: rows inserted into `_sqlite_mcp_meta` for db/tables/columns/recipes/clarification_fields.

- [ ] **Step 3: Restart MCP server (Claude Code)** and verify

In Claude Code, confirm `chiebukuro_query_cloud_knowledge` tool appears and `schema://cloud_knowledge` resource exists.

- [ ] **Step 4: Note (no commit needed for `~/chiebukuro-mcp/chiebukuro.json` if managed via dotfiles)** — confirm whether the json is symlinked from dotfiles. If yes, commit there.

---

# Phase H — Polish

## Task 32: README.md and CLAUDE.md

**Files:**
- Create: `README.md`
- Create: `CLAUDE.md`

- [ ] **Step 1: Create `README.md`** describing:
  - Purpose (1 paragraph)
  - Architecture diagram (copied from spec section 2.1)
  - Setup (rbenv local 4.0.1, bundle install, esa keychain token, anthropic api key)
  - APP_ENV table (dev/test/production)
  - Daily flow: `/cloud-knowledge-db-daily` slash command
  - Manual rake commands (fetch / translate / import / esa)
  - Operations tasks (scan_pollution / scan_contamination / find_duplicates / delete)
  - Reference to `docs/superpowers/specs/2026-04-16-cloud-knowledge-db-design.md` for full design

- [ ] **Step 2: Create `CLAUDE.md`** mirroring ruby-knowledge-db's CLAUDE.md structure but for cloud-knowledge-db. Include:
  - Project overview, language, DB, model strategy, MCP integration
  - Architecture diagram (sibling repos)
  - Collector interface contract
  - DB schema notes (1-article-2-records, source naming convention)
  - Development rules (Ruby only, TDD, bundle exec, conventional commits in English, .claude/ commits)
  - Important implementation notes:
    - CLAUDE.md contamination guard
    - Runtime model resolution
    - Two-stage bookmark
    - Host guard
  - APP_ENV matrix
  - Reference to chiebukuro-mcp meta_patches location

- [ ] **Step 3: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: add README and CLAUDE.md for cloud-knowledge-db"
```

---

## Task 33: End-to-end smoke in dev env

- [ ] **Step 1: Set required env vars / keychain**

```bash
# Anthropic API key
security find-generic-password -s anthropic-api-key -w >/dev/null 2>&1 || \
  security add-generic-password -a "$USER" -s anthropic-api-key -w "<your-key>"
export ANTHROPIC_API_KEY=$(security find-generic-password -s anthropic-api-key -w)

# esa token (if not already set)
security find-generic-password -s esa-mcp-token -w >/dev/null 2>&1 || \
  security add-generic-password -a "$USER" -s esa-mcp-token -w "<your-esa-token>"
```

- [ ] **Step 2: Run smoke endpoints**

```bash
APP_ENV=development bundle exec rake smoke:rss_endpoints
```

Expected: 5 sources, all 2xx (document and fix any failures before continuing).

- [ ] **Step 3: Run a single-source PoC for AWS yesterday**

```bash
APP_ENV=development \
  SINCE=$(date -v-1d +%Y-%m-%d) \
  BEFORE=$(date +%Y-%m-%d) \
  bundle exec rake fetch:aws_blog
# Capture DIR=...
DIR=<the printed dir>
APP_ENV=development DIR=$DIR bundle exec rake translate:aws_blog
APP_ENV=development DIR=$DIR bundle exec rake import:aws_blog
APP_ENV=development DIR=$DIR bundle exec rake esa:aws_blog
```

Expected:
- fetch: N records, MD files in tmpdir
- translate: each original MD has a paired translated MD
- import: stored=N, skipped=0
- esa: post number returned

- [ ] **Step 4: Verify with chiebukuro-mcp**

In Claude Code: `chiebukuro_query_cloud_knowledge` with `SELECT COUNT(*) FROM memories WHERE source LIKE 'aws/%'`. Expected: 2N rows (N original + N translated).

- [ ] **Step 5: Run contamination scan**

```bash
APP_ENV=development bundle exec rake db:scan_contamination
```

Expected: `Found 0 contaminated ids`.

- [ ] **Step 6: Document any issues encountered + fix or file follow-up tasks. Commit any fix**

---

# Self-Review

After all tasks above are written, verify against spec section by section:

- ✅ Spec §1.2 範囲内 → 公式4 + classmethod (Tasks 7, 10, 16); 翻訳 (Task 12); esa (Task 20); chiebukuro-mcp (Tasks 30-31); subagents (Tasks 26-28); bookmark + host_guard (Tasks 2, 4)
- ✅ Spec §2.1 リポ構造 → Task 1 (cloud-knowledge-db skeleton), Task 5 (cloud-blog-collector skeleton)
- ✅ Spec §3.4 1記事=2レコード → fetch writes original (source: */original), translate writes translated (source: official); import takes both
- ✅ Spec §4 4-phase pipeline → Tasks 17-21
- ✅ Spec §5 chiebukuro-mcp → Tasks 30-31
- ✅ Spec §6.3 翻訳プロンプト + コンタミ回避 → Task 12 (Translator + contamination test); Task 22 (db:scan_contamination)
- ✅ Spec §6.4 汚染検知 → Tasks 22, 23, 24, 25
- ✅ Spec §7 Token戦略 → Task 3 (ModelResolver), Tasks 12/13/14 (Haiku/Opus/Haiku assignments), Task 26-28 (subagent model frontmatter)
- ✅ Spec §8 subagent → Tasks 26-29
- ✅ Spec §9 テスト → tests created in Tasks 2-15; contamination test in Task 12
- ✅ Spec §10 ファイル構成 → all paths match
- ✅ Spec §11 APP_ENV 環境マトリクス → Task 2, Task 16
- ✅ Spec §13 実装フェーズ → Phases A-H map directly to spec's 12 step proposal

Placeholder scan: Search for "TBD", "TODO", "fill in", "appropriate error handling". → Only intended placeholders remain (e.g., "<your-key>" in keychain step, marked as user-supplied).

Type consistency:
- `Collector#fetch(since:, before:)` — used identically in Tasks 6, 7, 8, 10, 17
- `Translator#translate(md)` — used in Tasks 12, 18
- `DailySummarizer#summarize(provider_short:, date:, translated_articles:)` — used in Tasks 13, 20
- `ModelResolver#resolve(family)` — used in Tasks 3, 12, 13, 14
- `TrunkBookmark.mark_started/mark_completed/status/recommended_since_floor` — used in Tasks 4, 21
- `EsaWriter#post(name:, body_md:)` — used in Tasks 15, 20

Parallel naming check: source key suffix `_blog` is consistent across sources.yml, Rake namespaces, and bookmark keys.

---

# Execution Handoff

**Plan complete.** Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Choose and proceed.
