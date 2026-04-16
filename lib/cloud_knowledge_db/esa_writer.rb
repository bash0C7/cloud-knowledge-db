# frozen_string_literal: true
require 'net/http'
require 'uri'
require 'json'

module CloudKnowledgeDb
  class EsaWriter
    RATE_WAIT = 2

    attr_reader :team, :category, :wip

    def initialize(team:, category:, wip:)
      @team     = team
      @category = category
      @wip      = wip
    end

    def post(name:, body_md:)
      token = fetch_token
      uri   = URI("https://api.esa.io/v1/teams/#{@team}/posts")

      http         = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      req = Net::HTTP::Post.new(uri.path)
      req['Authorization'] = "Bearer #{token}"
      req['Content-Type']  = 'application/json'
      req.body = JSON.generate({
        post: { name: name, body_md: body_md, category: @category, wip: @wip }
      })

      res  = http.request(req)
      body = JSON.parse(res.body)

      sleep RATE_WAIT
      body
    ensure
      token = nil
    end

    private

    def fetch_token
      token = `/usr/bin/security find-generic-password -s 'esa-mcp-token' -w 2>/dev/null`.strip
      abort "ESA token not found in keychain (key: esa-mcp-token)" if token.empty?
      token
    end
  end
end
