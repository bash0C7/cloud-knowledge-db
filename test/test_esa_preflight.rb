# frozen_string_literal: true
require_relative 'test_helper'
require 'date'
require 'cloud_knowledge_db/esa_preflight'

class EsaPreflightTest < Test::Unit::TestCase
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
end
