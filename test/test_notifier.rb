# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/notifier'

class NotifierTest < Test::Unit::TestCase
  def setup
    @recorded = []
    @runner = ->(*args) { @recorded << args; true }
  end

  def test_notify_ok_uses_ok_title
    CloudKnowledgeDb::Notifier.notify(status: 'ok', since: '2026-04-29', before: '2026-04-30', runner: @runner)
    assert_equal 1, @recorded.size
    cmd = @recorded.first
    assert_equal 'osascript', cmd[0]
    assert_equal '-e', cmd[1]
    assert_match(/✓ daily ok/, cmd[2])
    assert_match(/2026-04-29/, cmd[2])
    assert_match(/2026-04-30/, cmd[2])
  end

  def test_notify_aborted_uses_reason_as_body
    CloudKnowledgeDb::Notifier.notify(status: 'aborted', reason: 'esa conflict: 2件', runner: @runner)
    cmd = @recorded.first
    assert_match(/⚠ daily aborted/, cmd[2])
    assert_match(/esa conflict: 2件/, cmd[2])
  end

  def test_notify_failed_uses_failed_title
    CloudKnowledgeDb::Notifier.notify(status: 'failed', reason: 'StandardError', runner: @runner)
    cmd = @recorded.first
    assert_match(/✗ daily failed/, cmd[2])
    assert_match(/StandardError/, cmd[2])
  end

  def test_notify_unknown_status_does_not_raise
    CloudKnowledgeDb::Notifier.notify(status: 'bogus', runner: @runner)
    assert_equal [], @recorded
  end

  def test_notify_runner_failure_is_swallowed
    raising_runner = ->(*_args) { raise 'osascript missing' }
    CloudKnowledgeDb::Notifier.notify(status: 'ok', runner: raising_runner)
    # if this returned, the rescue worked
    assert_true true
  end

  def test_notify_escapes_double_quote_in_reason
    CloudKnowledgeDb::Notifier.notify(status: 'failed', reason: 'got "boom"', runner: @runner)
    cmd = @recorded.first
    assert_match(/got \\"boom\\"/, cmd[2])
    refute_match(/got "boom"/, cmd[2])
  end

  def test_notify_escapes_backslash_in_reason
    CloudKnowledgeDb::Notifier.notify(status: 'failed', reason: 'path C:\\foo', runner: @runner)
    cmd = @recorded.first
    # Ruby string: path C:\\foo  → escape doubles backslash → path C:\\\\foo in script
    assert_match(/C:\\\\foo/, cmd[2])
  end
end
