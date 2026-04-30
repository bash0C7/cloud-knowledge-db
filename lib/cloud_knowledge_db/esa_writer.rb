# frozen_string_literal: true
require 'net/http'
require 'uri'
require 'json'
require_relative 'esa_token'

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
      raise "esa API error (#{res.code}): #{res.body}" if res.code.to_i >= 400
      body = JSON.parse(res.body)

      sleep RATE_WAIT
      body
    ensure
      token = nil
    end

    private

    def fetch_token
      EsaToken.fetch
    end
  end
end
