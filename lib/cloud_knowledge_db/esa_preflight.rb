# frozen_string_literal: true
require_relative 'esa_naming'

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
  end
end
