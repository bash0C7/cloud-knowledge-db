# frozen_string_literal: true
require_relative 'test_helper'
require 'date'
require 'cloud_knowledge_db/esa_preflight'

class EsaPreflightTest < Test::Unit::TestCase
  MockHttpResponse = Struct.new(:code, :body, keyword_init: true)
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

  def test_one_conflict_when_existing_post_returned
    searcher = CloudKnowledgeDb::EsaPreflight::StubSearcher.new(
      ['bist', 'test/cloud-trunk-changes/aws/2026/04/29', '2026-04-29-aws-cloud-changes'] => [
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

  def test_multi_day_window_expands_per_day
    searcher = CloudKnowledgeDb::EsaPreflight::StubSearcher.new(
      ['bist', 'test/cloud-trunk-changes/aws/2026/04/26', '2026-04-26-aws-cloud-changes'] => [
        { 'number' => 100, 'url' => 'https://bist.esa.io/posts/100' }
      ],
      ['bist', 'test/cloud-trunk-changes/aws/2026/04/29', '2026-04-29-aws-cloud-changes'] => [
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
      ['bist', 'test/c/aws/2026/04/29', '2026-04-29-aws-cloud-changes']    => [{ 'number' => 1, 'url' => 'u1' }],
      ['bist', 'test/c/gitlab/2026/04/29', '2026-04-29-gitlab-cloud-changes'] => [{ 'number' => 2, 'url' => 'u2' }]
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

  def test_default_searcher_builds_query_url
    captured = nil
    fake_http = ->(uri, _req) { captured = uri.to_s; MockHttpResponse.new(code: '200', body: '{"posts":[]}') }
    searcher = CloudKnowledgeDb::EsaPreflight::DefaultSearcher.new(
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
    fake_http = ->(_uri, _req) { MockHttpResponse.new(code: '200', body: '{"posts":[{"number":7,"url":"u"}]}') }
    searcher = CloudKnowledgeDb::EsaPreflight::DefaultSearcher.new(
      token: 'tok',
      http_runner: fake_http
    )
    posts = searcher.search(team: 'bist', category: 'c', name: 'n')
    assert_equal [{ 'number' => 7, 'url' => 'u' }], posts
  end

  def test_default_searcher_raises_on_4xx
    fake_http = ->(_uri, _req) { MockHttpResponse.new(code: '403', body: 'forbidden') }
    searcher = CloudKnowledgeDb::EsaPreflight::DefaultSearcher.new(
      token: 'tok',
      http_runner: fake_http
    )
    assert_raise(RuntimeError) do
      searcher.search(team: 'bist', category: 'c', name: 'n')
    end
  end

  def test_default_searcher_raises_clear_error_on_invalid_json
    fake_http = ->(_uri, _req) { MockHttpResponse.new(code: '200', body: '<html>not json</html>') }
    searcher = CloudKnowledgeDb::EsaPreflight::DefaultSearcher.new(
      token: 'tok',
      http_runner: fake_http
    )
    err = assert_raise(RuntimeError) do
      searcher.search(team: 'bist', category: 'c', name: 'n')
    end
    assert_match(/invalid JSON/, err.message)
  end

  def test_default_searcher_returns_empty_when_posts_key_missing
    fake_http = ->(_uri, _req) { MockHttpResponse.new(code: '200', body: '{}') }
    searcher = CloudKnowledgeDb::EsaPreflight::DefaultSearcher.new(
      token: 'tok',
      http_runner: fake_http
    )
    assert_equal [], searcher.search(team: 'bist', category: 'c', name: 'n')
  end
end
