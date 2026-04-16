# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/claude_runner'

class ClaudeRunnerTest < Test::Unit::TestCase
  def test_initializes_with_model
    runner = CloudKnowledgeDb::ClaudeRunner.new(model: 'haiku')
    assert_equal 'haiku', runner.instance_variable_get(:@model)
  end
end
