# frozen_string_literal: true
require 'open3'
require 'tmpdir'

module CloudKnowledgeDb
  class ClaudeRunner
    # @param model [String] "haiku" / "sonnet" / "opus"
    def initialize(model:)
      @model = model
    end

    # @param prompt [String] full prompt text
    # @return [String] claude output
    def execute(prompt)
      output = ""
      # chdir to /tmp to avoid CLAUDE.md contamination from any project directory
      Open3.popen3("claude", "--model", @model, "-p", "-", chdir: "/tmp") do |stdin, stdout, stderr, wt|
        stdin.write(prompt)
        stdin.close
        t1 = Thread.new { output = stdout.read }
        stderr.read
        t1.join
        wt.value
      end
      output.strip
    end
  end
end
