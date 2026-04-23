# frozen_string_literal: true

module Stats
  # Lightweight stats accumulator used by Orchestrator and IftttQueueProcessor.
  # Eliminates repeated Hash.new(0) / (|| 0) patterns and unifies increment API.
  #
  # Usage:
  #   stats = Stats::RunStats.new(processed: 0, published: 0, skipped: 0, errors: 0)
  #   stats.increment(:published)
  #   stats.fetch(:errors, 0)  # => 0
  #   stats.to_h               # => { processed: 0, published: 0, ... }
  class RunStats
    def initialize(**initial)
      @data = Hash.new(0).update(initial)
    end

    def increment(key)
      @data[key] += 1
      self
    end

    def [](key)     = @data[key]
    def fetch(...)  = @data.fetch(...)
    def to_h        = @data.dup
    def inspect     = "RunStats#{@data.inspect}"
    def to_s        = @data.inspect
  end
end
