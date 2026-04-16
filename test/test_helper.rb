# frozen_string_literal: true

ENV['APP_ENV'] ||= 'test'

require 'bundler/setup'
require 'test/unit'
require 'cloud_knowledge_db'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
