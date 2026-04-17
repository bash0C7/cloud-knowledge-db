# frozen_string_literal: true
require 'open3'

module CloudKnowledgeDb
  class OllamaRunner
    def self.ensure_available!
      out, status = Open3.capture2('ollama', 'list')
      return if status.success?
      raise RuntimeError,
            "ollama is not available (ollama list exit #{status.exitstatus}): #{out.lines.first}"
    rescue Errno::ENOENT
      raise RuntimeError,
            "ollama is not available: install ollama and start 'ollama serve' before running this task"
    end

    def initialize(model:)
      @model = model
    end

    # @param prompt [String] full prompt text
    # @return [String] ollama output, stripped
    def execute(prompt)
      output = ''
      Open3.popen3('ollama', 'run', @model) do |stdin, stdout, stderr, wt|
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
