# frozen_string_literal: true
require_relative 'test_helper'
require 'tmpdir'
require 'yaml'
require 'cloud_knowledge_db/trunk_bookmark'

class DailyPipelineTest < Test::Unit::TestCase
  # We test the pure-Ruby record_run logic in isolation by reproducing
  # the same algorithm. The actual Rakefile method is exercised in the
  # smoke test phase. This guards against accidental yml shape changes.

  def record_run_under_test(path, status, reason: nil, now: Time.now)
    data = CloudKnowledgeDb::TrunkBookmark.load(path)
    data['last_run'] = {
      'status'      => status,
      'finished_at' => now.iso8601,
      'reason'      => reason
    }
    CloudKnowledgeDb::TrunkBookmark.save(path, data)
  end

  def test_record_ok_writes_status_finished_at_and_nil_reason
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'last_run.yml')
      now  = Time.utc(2026, 4, 30, 0, 8, 30)
      record_run_under_test(path, 'ok', now: now)
      h = YAML.load_file(path)
      assert_equal 'ok', h['last_run']['status']
      assert_equal '2026-04-30T00:08:30Z', h['last_run']['finished_at']
      assert_nil h['last_run']['reason']
    end
  end

  def test_record_aborted_writes_reason
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'last_run.yml')
      record_run_under_test(path, 'aborted', reason: 'esa conflict: 2件')
      h = YAML.load_file(path)
      assert_equal 'aborted', h['last_run']['status']
      assert_equal 'esa conflict: 2件', h['last_run']['reason']
    end
  end

  def test_record_run_preserves_existing_per_source_blocks
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'last_run.yml')
      File.write(path, { 'aws_blog' => { 'last_completed_before' => '2026-04-29' } }.to_yaml)
      record_run_under_test(path, 'ok')
      h = YAML.load_file(path)
      assert_equal '2026-04-29', h['aws_blog']['last_completed_before']
      assert_equal 'ok', h['last_run']['status']
    end
  end
end
