# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/trunk_bookmark'
require 'tmpdir'
require 'fileutils'

class TrunkBookmarkTest < Test::Unit::TestCase
  TB = CloudKnowledgeDb::TrunkBookmark

  def test_load_missing_file_returns_empty
    Dir.mktmpdir do |dir|
      assert_equal({}, TB.load(File.join(dir, 'missing.yml')))
    end
  end

  def test_save_then_load_round_trip
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'last_run.yml')
      data = TB.mark_started({}, 'aws_blog', before: '2026-04-16', at: Time.parse('2026-04-16T09:00:00+09:00'))
      TB.save(path, data)
      loaded = TB.load(path)
      assert_equal '2026-04-16', loaded['aws_blog']['last_started_before']
    end
  end

  def test_status_detects_wip
    data = TB.mark_started({}, 'aws_blog', before: '2026-04-16', at: Time.now)
    snap = TB.status(data, %w[aws_blog gcp_blog])
    assert(snap['aws_blog'][:wip])
    assert_nil(snap['gcp_blog'][:last_started_before])
  end

  def test_status_completed_clears_wip
    data = {}
    data = TB.mark_started(data,   'aws_blog', before: '2026-04-16', at: Time.now)
    data = TB.mark_completed(data, 'aws_blog', before: '2026-04-16', at: Time.now)
    snap = TB.status(data, %w[aws_blog])
    assert_false(snap['aws_blog'][:wip])
  end

  def test_recommended_since_floor_picks_min
    data = {}
    data = TB.mark_completed(data, 'aws_blog', before: '2026-04-15', at: Time.now)
    data = TB.mark_completed(data, 'gcp_blog', before: '2026-04-10', at: Time.now)
    floor = TB.recommended_since_floor(data, %w[aws_blog gcp_blog])
    assert_equal '2026-04-10', floor
  end

  def test_recommended_since_floor_nil_if_any_missing
    data = TB.mark_completed({}, 'aws_blog', before: '2026-04-15', at: Time.now)
    floor = TB.recommended_since_floor(data, %w[aws_blog gcp_blog])
    assert_nil(floor)
  end
end
