# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/esa_naming'

class EsaNamingTest < Test::Unit::TestCase
  def test_build_name_has_no_slash
    name = CloudKnowledgeDb::EsaNaming.build_name(date: '2026-04-16', short_name: 'aws')
    assert_equal '2026-04-16-aws-cloud-changes', name
    assert_false name.include?('/'), 'name must not contain slash (esa API: name is title only)'
  end

  def test_build_category_appends_date_hierarchy
    category = CloudKnowledgeDb::EsaNaming.build_category(
      prefix: 'production/cloud-trunk-changes/aws',
      date:   '2026-04-16'
    )
    assert_equal 'production/cloud-trunk-changes/aws/2026/04/16', category
  end

  def test_period_key_day_keeps_full_date
    assert_equal '2026-08-15', CloudKnowledgeDb::EsaNaming.period_key('2026-08-15', period: 'day')
  end

  def test_period_key_month_truncates_to_year_month
    assert_equal '2026-08', CloudKnowledgeDb::EsaNaming.period_key('2026-08-15', period: 'month')
  end

  def test_month_key_builds_month_category_and_name
    key = CloudKnowledgeDb::EsaNaming.period_key('2026-08-15', period: 'month')
    assert_equal 'production/cloud-trunk-changes/aws/2026/08',
                 CloudKnowledgeDb::EsaNaming.build_category(prefix: 'production/cloud-trunk-changes/aws', date: key)
    assert_equal '2026-08-aws-cloud-changes',
                 CloudKnowledgeDb::EsaNaming.build_name(date: key, short_name: 'aws')
  end

  def test_full_name_does_not_double_prefix
    prefix = 'production/cloud-trunk-changes/aws'
    date   = '2026-04-16'
    category = CloudKnowledgeDb::EsaNaming.build_category(prefix: prefix, date: date)
    name     = CloudKnowledgeDb::EsaNaming.build_name(date: date, short_name: 'aws')

    full = "#{category}/#{name}"
    assert_equal 'production/cloud-trunk-changes/aws/2026/04/16/2026-04-16-aws-cloud-changes', full
    refute_match(/#{Regexp.escape(prefix)}\/.*#{Regexp.escape(prefix)}/, full,
                 'prefix must appear only once in full_name')
  end
end
