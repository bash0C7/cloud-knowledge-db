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
