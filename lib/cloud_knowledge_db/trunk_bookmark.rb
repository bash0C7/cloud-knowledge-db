# frozen_string_literal: true
require 'yaml'
require 'fileutils'
require 'time'

module CloudKnowledgeDb
  module TrunkBookmark
    module_function

    def load(path)
      return {} unless File.exist?(path)
      YAML.load_file(path) || {}
    end

    def save(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, data.to_yaml)
    end

    def mark_started(data, source_key, before:, at: Time.now)
      entry = data[source_key].is_a?(Hash) ? data[source_key].dup : {}
      entry['last_started_at']     = at.iso8601
      entry['last_started_before'] = before.to_s
      data[source_key] = entry
      data
    end

    def mark_completed(data, source_key, before:, at: Time.now, models_used: nil)
      entry = data[source_key].is_a?(Hash) ? data[source_key].dup : {}
      entry['last_completed_at']     = at.iso8601
      entry['last_completed_before'] = before.to_s
      entry['models_used']           = models_used if models_used
      data[source_key] = entry
      data
    end

    def status(data, source_keys)
      source_keys.each_with_object({}) do |key, acc|
        entry     = data[key].is_a?(Hash) ? data[key] : {}
        started   = entry['last_started_before']
        completed = entry['last_completed_before']
        wip = !started.nil? && (completed.nil? || started > completed)
        acc[key] = {
          last_started_at:       entry['last_started_at'],
          last_started_before:   started,
          last_completed_at:     entry['last_completed_at'],
          last_completed_before: completed,
          wip:                   wip,
          recommended_since:     completed
        }
      end
    end

    def recommended_since_floor(data, source_keys)
      completed = source_keys.map do |key|
        entry = data[key].is_a?(Hash) ? data[key] : {}
        entry['last_completed_before']
      end
      return nil if completed.any?(&:nil?)
      completed.min
    end
  end
end
