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
