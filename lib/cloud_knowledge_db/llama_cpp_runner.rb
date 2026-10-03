# frozen_string_literal: true
require 'net/http'
require 'json'
require 'uri'

module CloudKnowledgeDb
  # ollama 代替: llama.cpp (llama-server) の OpenAI 互換 /v1/chat/completions を叩く。
  # 既定は MBA 上の常駐 local llama-server (127.0.0.1:8081) なので、MBA 単体で完結する。
  # model: は OllamaRunner との interface 互換のために受け取るだけで、llama-server は
  # 1 プロセス = 1 モデルのため実際のリクエストボディには使わない(ログ用途のみ)。
  class LlamaCppRunner
    READ_TIMEOUT_SEC = 600

    def self.host
      ENV.fetch('LLAMA_SERVER_HOST', 'http://127.0.0.1:8081')
    end

    def self.ensure_available!
      uri = URI.join(host, '/health')
      res = Net::HTTP.get_response(uri)
      return if res.is_a?(Net::HTTPSuccess)

      raise RuntimeError,
            "llama-server is not available (#{uri} returned #{res.code}): " \
            'marionette-ma llm up local で起動してから実行してください'
    rescue Errno::ECONNREFUSED, SocketError => e
      raise RuntimeError,
            'llama-server is not available: marionette-ma llm up local で起動してから実行してください ' \
            "(#{e.class}: #{e.message})"
    end

    def initialize(model:)
      @model = model
    end

    # @param prompt [String] full prompt text
    # @return [String] model response, stripped
    def execute(prompt)
      uri = URI.join(self.class.host, '/v1/chat/completions')
      req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
      req.body = JSON.generate(
        messages: [{ role: 'user', content: prompt }],
        chat_template_kwargs: { enable_thinking: false },
      )
      res = Net::HTTP.start(uri.hostname, uri.port, read_timeout: READ_TIMEOUT_SEC) { |h| h.request(req) }
      unless res.is_a?(Net::HTTPSuccess)
        raise RuntimeError, "llama-server chat failed: HTTP #{res.code} #{res.body[0, 300]}"
      end

      JSON.parse(res.body).dig('choices', 0, 'message', 'content').to_s.strip
    end
  end
end
