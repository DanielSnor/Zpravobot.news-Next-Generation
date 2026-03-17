# frozen_string_literal: true

require_relative '../support/loggable'

module State
  # Shared base for all State repository classes.
  #
  # Provides:
  #   - Support::Loggable (log_info, log_warn, log_error)
  #   - @db accessor (PG connection wrapper from DatabaseConnection)
  #
  # Subclasses own their error handling — rescue PG::Error and fallback
  # values vary per method and are not extracted here.
  class BaseRepository
    include Support::Loggable

    def initialize(db)
      @db = db
    end
  end
end
