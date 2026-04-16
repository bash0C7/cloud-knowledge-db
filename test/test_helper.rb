# frozen_string_literal: true

ENV['APP_ENV'] ||= 'test'

require 'bundler/setup'
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'test/unit'
require 'cloud_knowledge_db'
