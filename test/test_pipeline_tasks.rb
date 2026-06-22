# frozen_string_literal: true
require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'date'
require 'cloud_knowledge_db/pipeline'
require 'cloud_knowledge_db/trunk_bookmark'

FakeConflict = Struct.new(:to_h) unless defined?(FakeConflict)

class TestPipelineStart < Test::Unit::TestCase
  def setup
    @dir          = Dir.mktmpdir
    @bookmark     = File.join(@dir, 'last_run.yml')
    @since        = Date.parse('2026-06-22')
    @before       = Date.parse('2026-06-23')
    @cfg = {
      'sources' => {
        'aws_blog' => {}, 'gcp_blog' => {}, 'classmethod_blog' => {}
      },
      'models' => {
        'daily_summarizer' => { 'provider' => 'local_ollama', 'model' => 'gemma4' }
      }
    }
    @no_conflicts  = ->(**) { [] }
    @has_conflicts = ->(**) { [FakeConflict.new({ base_name: 'Conflict' })] }
  end

  def teardown
    FileUtils.rm_rf(@dir)
    ENV.delete('CKDB_FORCE')
  end

  def test_start_writes_mark_started_for_all_sources
    result = CloudKnowledgeDb::Pipeline.start(
      cfg: @cfg, bookmark_path: @bookmark,
      since: @since, before: @before, preflight: @no_conflicts
    )

    assert_equal :ok, result[:status]
    data = CloudKnowledgeDb::TrunkBookmark.load(@bookmark)
    %w[aws_blog gcp_blog classmethod_blog].each do |key|
      assert_equal @before.to_s, data.dig(key, 'last_started_before'),
                   "#{key}: last_started_before not written"
    end
  end

  def test_start_returns_aborted_when_conflicts_exist
    result = CloudKnowledgeDb::Pipeline.start(
      cfg: @cfg, bookmark_path: @bookmark,
      since: @since, before: @before, preflight: @has_conflicts
    )

    assert_equal :aborted, result[:status]
    assert_not_empty result[:conflicts]
    assert_false File.exist?(@bookmark), 'bookmark must not be written on abort'
  end

  def test_start_ignores_conflicts_when_ckdb_force_set
    ENV['CKDB_FORCE'] = '1'
    result = CloudKnowledgeDb::Pipeline.start(
      cfg: @cfg, bookmark_path: @bookmark,
      since: @since, before: @before, preflight: @has_conflicts
    )

    assert_equal :ok, result[:status]
  end
end

class TestPipelineFinish < Test::Unit::TestCase
  def setup
    @dir      = Dir.mktmpdir
    @bookmark = File.join(@dir, 'last_run.yml')
    @since    = Date.parse('2026-06-22')
    @before   = Date.parse('2026-06-23')
    @cfg = {
      'sources' => {
        'aws_blog' => {}, 'gcp_blog' => {}, 'classmethod_blog' => {}
      },
      'models' => {
        'daily_summarizer' => { 'provider' => 'local_ollama', 'model' => 'gemma4' }
      }
    }
    # Pre-populate bookmark as if pipeline:start already ran
    data = {}
    %w[aws_blog gcp_blog classmethod_blog].each do |k|
      data = CloudKnowledgeDb::TrunkBookmark.mark_started(data, k, before: @before)
    end
    CloudKnowledgeDb::TrunkBookmark.save(@bookmark, data)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_finish_marks_completed_for_successful_sources
    result = CloudKnowledgeDb::Pipeline.finish(
      cfg: @cfg, bookmark_path: @bookmark,
      completed: %w[aws_blog gcp_blog], failed: [],
      since: @since, before: @before
    )

    assert_equal 'ok', result[:status]
    assert_nil result[:reason]
    data = CloudKnowledgeDb::TrunkBookmark.load(@bookmark)
    assert_equal @before.to_s, data.dig('aws_blog',  'last_completed_before')
    assert_equal @before.to_s, data.dig('gcp_blog',  'last_completed_before')
    assert_nil   data.dig('classmethod_blog', 'last_completed_before'),
                 'failed source must not be marked completed'
  end

  def test_finish_status_partial_failed_when_some_sources_failed
    result = CloudKnowledgeDb::Pipeline.finish(
      cfg: @cfg, bookmark_path: @bookmark,
      completed: %w[aws_blog], failed: %w[gcp_blog classmethod_blog],
      since: @since, before: @before
    )

    assert_equal 'partial_failed', result[:status]
    assert_match(/gcp_blog/,        result[:reason])
    assert_match(/classmethod_blog/, result[:reason])
  end

  def test_finish_writes_models_used_for_completed_sources
    result = CloudKnowledgeDb::Pipeline.finish(
      cfg: @cfg, bookmark_path: @bookmark,
      completed: %w[aws_blog], failed: [],
      since: @since, before: @before
    )

    assert_equal 'ok', result[:status]
    data = CloudKnowledgeDb::TrunkBookmark.load(@bookmark)
    assert_equal 'gemma4', data.dig('aws_blog', 'models_used', 'daily_summarizer', 'model')
  end
end
