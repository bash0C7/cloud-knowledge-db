# frozen_string_literal: true
require 'net/http'
require 'uri'
require 'json'
require_relative 'esa_naming'
require_relative 'esa_token'

module CloudKnowledgeDb
  module EsaPreflight
    Conflict = Struct.new(
      :source, :date, :name, :category,
      :existing_post_number, :existing_post_url,
      keyword_init: true
    )

    def self.conflicts(cfg:, since:, before:, searcher:)
      results = []
      team = cfg.dig('esa', 'team')
      cfg.dig('esa', 'sources').each do |source_key, esa_src|
        short = cfg.dig('sources', source_key, 'short_name')
        (since...before).each do |date|
          date_str = date.to_s
          name     = EsaNaming.build_name(date: date_str, short_name: short)
          category = EsaNaming.build_category(prefix: esa_src['category'], date: date_str)
          posts    = searcher.search(team: team, category: category, name: name) || []
          posts.each do |p|
            results << Conflict.new(
              source: source_key, date: date_str,
              name: name, category: category,
              existing_post_number: p['number'],
              existing_post_url:    p['url']
            )
          end
        end
      end
      results
    end

    class StubSearcher
      def initialize(posts_by_query = {})
        @posts_by_query = posts_by_query
      end

      def search(team:, category:, name:)
        @posts_by_query[[team, category, name]] || []
      end
    end

    class DefaultSearcher
      def initialize(cfg:, token: nil, http_runner: nil)
        @cfg         = cfg
        @token       = token || EsaToken.fetch
        @http_runner = http_runner || method(:default_http_call)
      end

      def search(team:, category:, name:)
        q = URI.encode_www_form_component("category:#{category} name:#{name}")
        uri = URI("https://api.esa.io/v1/teams/#{team}/posts?q=#{q}&per_page=100")
        req = Net::HTTP::Get.new(uri.request_uri)
        req['Authorization'] = "Bearer #{@token}"
        res = @http_runner.call(uri, req)
        raise "esa API error (#{res.code}): #{res.body}" if res.code.to_i >= 400
        JSON.parse(res.body)['posts'] || []
      end

      private

      def default_http_call(uri, req)
        Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
      end
    end
  end
end
