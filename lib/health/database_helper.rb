# frozen_string_literal: true

require 'pg'
require_relative '../utils/database_helpers'

module DatabaseHelper
  def connect_db
    db_config = @config[:database]

    if db_config[:url]
      @conn = PG.connect(db_config[:url])
    else
      @conn = PG.connect(
        host: db_config[:host],
        dbname: db_config[:dbname],
        user: db_config[:user],
        password: db_config[:password]
      )
    end
    DatabaseHelpers.validate_schema!(db_config[:schema])
    @conn.exec("SET search_path TO #{db_config[:schema]}")
  end
end
