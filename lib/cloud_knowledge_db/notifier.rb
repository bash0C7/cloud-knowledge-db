# frozen_string_literal: true

module CloudKnowledgeDb
  module Notifier
    TITLES = {
      'ok'      => '✓ daily ok',
      'aborted' => '⚠ daily aborted',
      'failed'  => '✗ daily failed'
    }.freeze

    def self.notify(status:, since: nil, before: nil, reason: nil, runner: nil)
      title = TITLES[status]
      return unless title
      body   = reason || "[#{since}, #{before})"
      script = %Q(display notification "#{escape(body)}" with title "#{escape(title)}")
      r = runner || method(:default_run)
      r.call('osascript', '-e', script)
    rescue => e
      warn "[notifier] failed: #{e.message}"
    end

    def self.escape(s)
      s.to_s.gsub('\\', '\\\\\\\\').gsub('"', '\\\\"')
    end

    def self.default_run(*args)
      system(*args)
    end
  end
end
