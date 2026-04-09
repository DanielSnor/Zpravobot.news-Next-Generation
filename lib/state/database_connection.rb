# frozen_string_literal: true

require 'pg'
require_relative '../utils/database_helpers'
require_relative '../support/loggable'

module State
  # Manages PostgreSQL database connection lifecycle
  # Shared dependency for all repository classes
  class DatabaseConnection
    include Support::Loggable

    DEFAULT_SCHEMA = 'zpravobot'
    PING_INTERVAL = 300 # 5 minutes — ping only after idle periods, not every query

    attr_reader :schema

    def initialize(url: nil, host: nil, port: 5432, dbname: nil, user: nil, password: nil, schema: nil)
      @schema = schema || ENV.fetch('ZPRAVOBOT_SCHEMA', DEFAULT_SCHEMA)
      @last_ping = nil
      @connection_params = if url
        { conninfo: url }
      elsif host
        { host: host, port: port, dbname: dbname, user: user, password: password }.compact
      elsif ENV['CLOUDRON_POSTGRESQL_URL']
        { conninfo: ENV['CLOUDRON_POSTGRESQL_URL'] }
      elsif ENV['DATABASE_URL']
        { conninfo: ENV['DATABASE_URL'] }
      else
        {
          host: ENV.fetch('ZPRAVOBOT_DB_HOST', 'localhost'),
          port: ENV.fetch('ZPRAVOBOT_DB_PORT', 5432).to_i,
          dbname: ENV.fetch('ZPRAVOBOT_DB_NAME', 'zpravobot'),
          user: ENV.fetch('ZPRAVOBOT_DB_USER', 'zpravobot_app'),
          password: ENV['ZPRAVOBOT_DB_PASSWORD']
        }.compact
      end
      @conn = nil
    end

    def connect
      return @conn if @conn && !@conn.finished?

      if @connection_params[:conninfo]
        @conn = PG.connect(@connection_params[:conninfo])
      else
        @conn = PG.connect(**@connection_params)
      end

      DatabaseHelpers.validate_schema!(@schema)
      @conn.exec("SET search_path TO #{@schema}")
      @conn.exec('SELECT 1') # Verify connection is alive
      @last_ping = Time.now
      log_debug("Connected to database (schema: #{@schema})")
      @conn
    end

    def disconnect
      return unless @conn && !@conn.finished?

      @conn.close
      @conn = nil
      log_debug('Disconnected from database')
    end

    def connected?
      @conn && !@conn.finished?
    end

    def ensure_connection
      if @conn && !@conn.finished?
        # Periodically verify connection is still alive (catches server-side idle drops)
        if @last_ping.nil? || (Time.now - @last_ping) > PING_INTERVAL
          begin
            @conn.exec('SELECT 1')
            @last_ping = Time.now
          rescue PG::Error
            log_warn('DB connection stale, reconnecting...')
            @conn = nil
          end
        end
      end
      connect unless @conn && !@conn.finished?
      @conn
    end

    # Expose raw connection for repositories
    def conn
      ensure_connection
    rescue PG::Error => e
      log_warn("DB connection failed, reconnecting: #{e.message}")
      @conn = nil
      connect
    end
  end
end
