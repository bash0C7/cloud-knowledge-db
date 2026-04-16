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

def write_md(dir, fname, frontmatter, body)
  require 'yaml'
  fm_yaml = frontmatter.transform_keys(&:to_s).to_yaml.sub(/^---\n/, '')
  File.write(File.join(dir, fname), "---\n#{fm_yaml}---\n#{body}\n")
end

def parse_md(path)
  require 'yaml'
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
  require 'digest'
  require 'uri'
  return Digest::SHA256.hexdigest('')[0, 8] if url.nil? || url.empty?
  tail = URI.parse(url).path.split('/').reject(&:empty?).last || ''
  tail.empty? ? Digest::SHA256.hexdigest(url)[0, 8] : tail
end

def do_fetch(key, since:, before:)
  require 'bundler/setup'
  require 'cloud_blog_collector'
  require 'tmpdir'
  src_cfg = cfg['sources'][key] or abort "unknown source: #{key}"
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

def do_translate(key, dir:)
  require 'bundler/setup'
  require 'anthropic'
  require_relative 'lib/cloud_knowledge_db/translator'
  require_relative 'lib/cloud_knowledge_db/model_resolver'

  src_cfg = cfg['sources'][key] or abort "unknown source: #{key}"
  return if src_cfg['adapter'] == 'classmethod'

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

def do_import(key, dir:)
  require 'bundler/setup'
  require 'ruby_knowledge_store'

  src_cfg = cfg['sources'][key] or abort "unknown source: #{key}"
  pattern = "*-#{src_cfg['short_name']}-*.md"

  store = build_store
  stored, skipped = 0, 0

  Dir.glob(File.join(dir, pattern)).each do |path|
    fm, body = parse_md(path)
    next if fm.nil? || body.nil?
    result = store.store(body, source: fm['source'])
    if result.nil?
      skipped += 1
    else
      stored += 1
    end
  end
  puts "import #{key}: stored=#{stored}, skipped=#{skipped}"
end

def do_esa(key, dir:)
  require 'bundler/setup'
  require 'anthropic'
  require_relative 'lib/cloud_knowledge_db/esa_writer'
  require_relative 'lib/cloud_knowledge_db/daily_summarizer'
  require_relative 'lib/cloud_knowledge_db/model_resolver'

  src_cfg = cfg['sources'][key] or abort "unknown source: #{key}"

  if src_cfg['adapter'] == 'classmethod'
    puts "esa #{key}: skipped (classmethod is DB-only)"
    return
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

  ja_paths = Dir.glob(File.join(dir, "*-#{src_cfg['short_name']}-*.md"))
                .reject { |p| File.basename(p).include?('-original-') }
  grouped  = ja_paths.group_by { |p| File.basename(p)[/^\d{4}-\d{2}-\d{2}/] }

  grouped.each do |date, paths|
    next if date.nil?
    articles = paths.filter_map do |p|
      fm, body = parse_md(p)
      next if fm.nil? || body.nil?
      { title: fm['title'], url: fm['origin_url'] || fm['url'], body_ja: body }
    end
    next if articles.empty?

    body_md = summarizer.summarize(provider_short: src_cfg['short_name'], date: date, translated_articles: articles)
    full_path = "#{esa_cfg['category']}/#{date.tr('-','/')}/#{date}-#{src_cfg['short_name']}-cloud-changes"
    result = writer.post(name: full_path, body_md: body_md)
    puts "Posted: ##{result['number']} #{result['full_name']}" if result['number']
  end
end

def build_store
  require 'ruby_knowledge_store'
  CloudKnowledgeDb::Config.ensure_write_host!
  db = File.expand_path(cfg['db_path'], __dir__)
  RubyKnowledgeStore::Migrator.new(db, migrations_dir: RubyKnowledgeStore::MIGRATIONS_DIR).run
  RubyKnowledgeStore::Store.new(db, embedder: RubyKnowledgeStore::Embedder.new)
end

# ---- Source-keyed task namespaces ----

source_keys = begin; cfg['sources'].keys; rescue; []; end

namespace :fetch do
  source_keys.each do |key|
    desc "fetch source=#{key}"
    task key.to_sym do
      require 'time'
      CloudKnowledgeDb::Config.ensure_write_host!
      since  = ENV['SINCE']  ? Time.parse(ENV['SINCE'])  : nil
      before = ENV['BEFORE'] ? Time.parse(ENV['BEFORE']) : Time.now
      dir = do_fetch(key, since: since, before: before)
      puts "DIR=#{dir}"
    end
  end
end

namespace :translate do
  source_keys.each do |key|
    desc "translate fetched MDs in DIR for source=#{key}"
    task key.to_sym do
      CloudKnowledgeDb::Config.ensure_write_host!
      dir = ENV['DIR'] or abort 'DIR is required'
      do_translate(key, dir: dir)
    end
  end
end

namespace :import do
  source_keys.each do |key|
    desc "import MDs in DIR for source=#{key}"
    task key.to_sym do
      CloudKnowledgeDb::Config.ensure_write_host!
      dir = ENV['DIR'] or abort 'DIR is required'
      do_import(key, dir: dir)
    end
  end
end

namespace :esa do
  source_keys.each do |key|
    desc "post DailySummarizer article for source=#{key}"
    task key.to_sym do
      CloudKnowledgeDb::Config.ensure_write_host!
      dir = ENV['DIR'] or abort 'DIR is required'
      do_esa(key, dir: dir)
    end
  end

  desc 'Find duplicate posts (same base name, optional DATE=YYYY-MM-DD)'
  task :find_duplicates do
    require 'bundler/setup'
    require 'net/http'
    require 'uri'
    require 'json'

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

  desc 'DESTRUCTIVE delete esa posts by IDS=104,110'
  task :delete do
    CloudKnowledgeDb::Config.ensure_write_host!
    require 'net/http'
    require 'uri'

    ids = (ENV['IDS'] || '').split(',').map { |s| Integer(s.strip) }
    abort 'IDS is required' if ids.empty?
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

namespace :db do
  desc 'Scan for pollution markers'
  task :scan_pollution do
    require 'bundler/setup'
    require 'sqlite3'
    require 'sqlite_vec'

    db_path = File.expand_path(cfg['db_path'], __dir__)
    abort "DB not found: #{db_path}" unless File.exist?(db_path)
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
        FROM memories GROUP BY source, substr(content,1,200) HAVING c > 1
    SQL
    dup.each { |s, head, ids, c| puts "dup source=#{s} count=#{c} ids=#{ids}" }
    puts "Found #{bad_ids.uniq.length} polluted ids"
  end

  desc 'Scan for CLAUDE.md contamination markers'
  task :scan_contamination do
    require 'bundler/setup'
    require 'sqlite3'

    db_path = File.expand_path(cfg['db_path'], __dir__)
    abort "DB not found: #{db_path}" unless File.exist?(db_path)
    db = SQLite3::Database.new(db_path)

    markers = %w[ピョン チェケラッチョ じゃりんこ ウチ あんさん 質問？ 確認？ 了解。 提案。 不明。 理解。]
    hits = []
    markers.each do |m|
      rows = db.execute('SELECT id, source FROM memories WHERE content LIKE ?', ["%#{m}%"])
      rows.each { |id, src| puts "contam[#{m}] id=#{id} source=#{src}"; hits << id }
    end
    puts "Found #{hits.uniq.length} contaminated ids"
  end

  desc 'Show DB statistics (row counts per source)'
  task :stats do
    require 'bundler/setup'
    require 'sqlite3'
    require 'sqlite_vec'

    db_path = File.expand_path(cfg['db_path'], __dir__)
    abort "DB not found: #{db_path}" unless File.exist?(db_path)
    db = SQLite3::Database.new(db_path)
    db.enable_load_extension(true)
    SqliteVec.load(db)

    total = db.get_first_value('SELECT COUNT(*) FROM memories')
    puts "Total memories: #{total}"
    puts "---"
    rows = db.execute('SELECT source, COUNT(*) c FROM memories GROUP BY source ORDER BY c DESC')
    rows.each { |src, c| puts "  #{src}: #{c}" }
    puts "---"
    vec_count = db.get_first_value('SELECT COUNT(*) FROM memories_vec')
    puts "Total vectors: #{vec_count}"
  end

  desc 'DESTRUCTIVE delete by IDS=1,2,3'
  task :delete_polluted do
    CloudKnowledgeDb::Config.ensure_write_host!
    require 'bundler/setup'
    require 'sqlite3'
    require 'sqlite_vec'

    ids = (ENV['IDS'] || '').split(',').map { |s| Integer(s.strip) }
    abort 'IDS is required' if ids.empty?

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
end

namespace :smoke do
  desc 'HEAD-check all configured feed URLs'
  task :rss_endpoints do
    require 'bundler/setup'
    require 'net/http'
    require 'uri'

    cfg['sources'].each do |key, src|
      url = src['feed_url'] || src['index_url']
      next unless url
      begin
        uri = URI(url)
        req = Net::HTTP::Head.new(uri.request_uri)
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 10, read_timeout: 10) { |h| h.request(req) }
        puts "#{key}\t#{res.code}\t#{url}"
      rescue => e
        puts "#{key}\tERROR\t#{url}\t#{e.message}"
      end
    end
  end
end

desc 'Run the full daily pipeline across all sources'
task :daily do
  require 'bundler/setup'
  require 'date'
  require 'time'

  CloudKnowledgeDb::Config.ensure_write_host!

  before = ENV['BEFORE'] ? Date.parse(ENV['BEFORE']) : Date.today
  since  = ENV['SINCE']  ? Date.parse(ENV['SINCE'])  : (before - 1)

  data = TB.load(LAST_RUN_PATH)

  cfg['sources'].keys.each do |key|
    puts "==== #{key} (#{since}..#{before}) ===="
    data = TB.mark_started(data, key, before: before, at: Time.now)
    TB.save(LAST_RUN_PATH, data)

    dir = do_fetch(key, since: since.to_time, before: before.to_time)

    do_translate(key, dir: dir)
    do_import(key, dir: dir)
    do_esa(key, dir: dir)

    data = TB.mark_completed(data, key, before: before, at: Time.now,
      models_used: { 'translator' => cfg['models']['translator'], 'daily_summarizer' => cfg['models']['daily_summarizer'] })
    TB.save(LAST_RUN_PATH, data)
  end
end
