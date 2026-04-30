# frozen_string_literal: true
require_relative 'test_helper'
require 'cloud_knowledge_db/esa_token'

class EsaTokenTest < Test::Unit::TestCase
  def test_fetch_returns_stripped_token
    runner = -> { "abc123\n" }
    assert_equal 'abc123', CloudKnowledgeDb::EsaToken.fetch(runner: runner)
  end

  def test_fetch_raises_when_token_empty
    runner = -> { "" }
    assert_raise(RuntimeError) do
      CloudKnowledgeDb::EsaToken.fetch(runner: runner)
    end
  end

  def test_fetch_raises_when_token_whitespace_only
    runner = -> { "   \n" }
    assert_raise(RuntimeError) do
      CloudKnowledgeDb::EsaToken.fetch(runner: runner)
    end
  end
end
