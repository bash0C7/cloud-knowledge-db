# frozen_string_literal: true

module CloudKnowledgeDb
  module EsaToken
    KEY = 'esa-mcp-token'

    def self.fetch(runner: nil)
      r = runner || method(:default_fetch)
      token = r.call.to_s.strip
      raise "ESA token not found in keychain (key: #{KEY})" if token.empty?
      token
    end

    def self.default_fetch
      `/usr/bin/security find-generic-password -s '#{KEY}' -w 2>/dev/null`
    end
  end
end
