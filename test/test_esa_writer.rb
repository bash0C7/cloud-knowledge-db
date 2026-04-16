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
