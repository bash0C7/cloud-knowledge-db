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
      body = reason || "[#{since}, #{before})"
      r = runner || method(:default_run)
      r.call('osascript', '-e', %Q(display notification "#{body}" with title "#{title}"))
    rescue => e
      warn "[notifier] failed: #{e.message}"
    end

    def self.default_run(*args)
      system(*args)
    end
  end
end
