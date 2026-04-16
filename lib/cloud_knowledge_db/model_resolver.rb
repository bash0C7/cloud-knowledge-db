# frozen_string_literal: true

module CloudKnowledgeDb
  class ModelResolver
    FAMILIES = %w[haiku sonnet opus].freeze

    def initialize(client:)
      @client = client
      @cache  = {}
    end

    # @param family [String, Symbol]
    # @return [String] full model id
    def resolve(family)
      family = family.to_s
      raise ArgumentError, "unknown family: #{family}" unless FAMILIES.include?(family)

      pin = ENV["CLOUD_KB_PIN_#{family.upcase}"]
      return pin if pin && !pin.empty?

      @cache[family] ||= fetch_latest(family)
    end

    private

    def fetch_latest(family)
      models = @client.models.list
      candidates = models.data.select { |m| m.id.start_with?("claude-#{family}-") }
      raise "no model for family: #{family}" if candidates.empty?
      candidates.max_by { |m| version_tuple(m.id) }.id
    end

    def version_tuple(id)
      id.scan(/\d+/).map(&:to_i)
    end
  end
end
