# frozen_string_literal: true
require 'net/http'
require 'json'
require 'uri'

module CloudKnowledgeDb
  class OllamaRunner
    READ_TIMEOUT_SEC = 600

    def self.host
      ENV.fetch('OLLAMA_HOST', 'http://localhost:11434')
    end

    def self.ensure_available!
      uri = URI.join(host, '/api/tags')
      res = Net::HTTP.get_response(uri)
      return if res.is_a?(Net::HTTPSuccess)
      raise RuntimeError,
            "ollama is not available (#{uri} returned #{res.code}): start 'ollama serve' before running this task"
    rescue Errno::ECONNREFUSED, SocketError => e
      raise RuntimeError,
            "ollama is not available: start 'ollama serve' before running this task (#{e.class}: #{e.message})"
    end

    def initialize(model:)
      @model = model
    end

    # @param prompt [String] full prompt text
    # @return [String] model response, stripped
    def execute(prompt)
      uri = URI.join(self.class.host, '/api/generate')
      req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
      req.body = JSON.generate(model: @model, prompt: prompt, stream: false, think: false)
      res = Net::HTTP.start(uri.hostname, uri.port, read_timeout: READ_TIMEOUT_SEC) { |h| h.request(req) }
      raise RuntimeError, "ollama generate failed: HTTP #{res.code} #{res.body[0, 300]}" unless res.is_a?(Net::HTTPSuccess)
      JSON.parse(res.body).fetch('response', '').strip
    end
  end
end
