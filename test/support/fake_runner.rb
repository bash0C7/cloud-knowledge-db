# frozen_string_literal: true

# Test double for CloudKnowledgeDb::ClaudeRunner.
# Swap via instance_variable_set(:@runner, FakeRunner.new('response'))
class FakeRunner
  attr_accessor :response
  attr_reader :last_prompt

  def initialize(response = '')
    @response = response
    @last_prompt = nil
  end

  def execute(prompt)
    @last_prompt = prompt
    @response
  end
end
