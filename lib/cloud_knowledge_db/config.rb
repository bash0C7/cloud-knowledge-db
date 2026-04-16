# frozen_string_literal: true
require 'yaml'

module CloudKnowledgeDb
  module Config
    APP_ENV    = ENV.fetch('APP_ENV', 'development')
    CONFIG_DIR = File.expand_path('../../config', __dir__)

    def self.load
      sources  = YAML.load_file(File.join(CONFIG_DIR, 'sources.yml'))
      env_file = File.join(CONFIG_DIR, 'environments', "#{APP_ENV}.yml")
      abort "Unknown APP_ENV: #{APP_ENV} (no file: #{env_file})" unless File.exist?(env_file)
      env_cfg  = YAML.load_file(env_file)
      sources.merge(env_cfg)
    end

    # 書き込み系タスクを特定 Mac に限定する暫定ガード。
    # ALLOW_WRITE=1 で一時バイパス可。allowed_write_host 未設定の env は素通し。
    def self.ensure_write_host!
      host = load['allowed_write_host']
      return unless host
      return if ENV['ALLOW_WRITE'] == '1'
      current = `scutil --get LocalHostName 2>/dev/null`.strip
      current = `hostname 2>/dev/null`.strip.split('.').first if current.empty?
      return if current == host
      abort "Refusing to write: current host '#{current}' != allowed_write_host '#{host}' (APP_ENV=#{APP_ENV}). Set ALLOW_WRITE=1 to bypass."
    end
  end
end
