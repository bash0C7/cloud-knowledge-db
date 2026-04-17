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
    # @return [String] ollama stdout only, stripped
    def execute(prompt)
      # --hidethinking + --think=false: stop gemma family from emitting chain-of-thought.
      # --nowordwrap: stop ollama from injecting ANSI cursor-rewind escapes.
      out, _status = Open3.capture2(
        'ollama', 'run',
        '--hidethinking', '--think=false', '--nowordwrap',
        @model,
        stdin_data: prompt
      )
      out.strip
    end
  end
end
