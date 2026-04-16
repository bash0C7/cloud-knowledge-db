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
