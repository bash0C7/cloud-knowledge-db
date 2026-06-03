# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/esa_duplicates'

class EsaDuplicatesTest < Test::Unit::TestCase
  # esa post stub: name + number + full_name のみ使う
  def post(number, name, full_name = nil)
    { 'number' => number, 'name' => name, 'full_name' => full_name || name }
  end

  def test_groups_by_base_name_stripping_suffix
    posts = [
      post(308, '2026-06-01-aws-cloud-changes'),
      post(321, '2026-06-01-aws-cloud-changes (1)'),
      post(309, '2026-06-01-gcp-cloud-changes'),
    ]
    groups = CloudKnowledgeDb::EsaDuplicates.duplicate_groups(posts: posts)

    assert_equal 1, groups.length, 'gcp は単独なので重複に含めない'
    g = groups.first
    assert_equal '2026-06-01-aws-cloud-changes', g[:base_name]
    assert_equal [308, 321], g[:posts].map { |p| p['number'] }.sort
  end

  def test_no_duplicates_returns_empty
    posts = [
      post(308, '2026-06-01-aws-cloud-changes'),
      post(309, '2026-06-01-gcp-cloud-changes'),
    ]
    groups = CloudKnowledgeDb::EsaDuplicates.duplicate_groups(posts: posts)
    assert_equal [], groups
  end

  # 回帰テスト: content date と esa 作成日が異なる後日再投稿でも、
  # name 先頭の content date で filter できること（created: フィルタの偽陰性バグ）
  def test_date_filter_uses_content_date_in_name_not_created_at
    posts = [
      post(308, '2026-06-01-aws-cloud-changes'),       # content 2026-06-01, 作成 06-02
      post(321, '2026-06-01-aws-cloud-changes (1)'),   # content 2026-06-01, 作成 06-03
      post(330, '2026-06-02-aws-cloud-changes'),       # 別 date
    ]
    groups = CloudKnowledgeDb::EsaDuplicates.duplicate_groups(posts: posts, date: '2026-06-01')

    assert_equal 1, groups.length
    assert_equal '2026-06-01-aws-cloud-changes', groups.first[:base_name]
    assert_equal [308, 321], groups.first[:posts].map { |p| p['number'] }.sort
  end

  def test_date_filter_excludes_other_dates
    posts = [
      post(330, '2026-06-02-aws-cloud-changes'),
      post(331, '2026-06-02-aws-cloud-changes (1)'),
    ]
    groups = CloudKnowledgeDb::EsaDuplicates.duplicate_groups(posts: posts, date: '2026-06-01')
    assert_equal [], groups, '2026-06-01 指定なら 06-02 の重複は対象外'
  end

  def test_nil_or_empty_posts
    assert_equal [], CloudKnowledgeDb::EsaDuplicates.duplicate_groups(posts: nil)
    assert_equal [], CloudKnowledgeDb::EsaDuplicates.duplicate_groups(posts: [])
  end
end
