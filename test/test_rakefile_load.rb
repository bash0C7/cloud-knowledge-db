# frozen_string_literal: true
require_relative 'test_helper'
require 'open3'
require 'rbconfig'

class RakefileLoadTest < Test::Unit::TestCase
  ROOT = File.expand_path('..', __dir__)

  def test_runner_is_defined_after_loading_rakefile
    script = "require 'rake'; load 'Rakefile'; print defined?(CloudKnowledgeDb::Runner).inspect"
    out, err, status = Open3.capture3(RbConfig.ruby, '-e', script, chdir: ROOT)
    assert status.success?, err
    assert_equal '"constant"', out
  end
end
