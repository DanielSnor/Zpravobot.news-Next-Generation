# frozen_string_literal: true

require 'yaml'
require 'fileutils'
require 'time'

begin
  require 'pg'
  PG_AVAILABLE = true unless defined?(PG_AVAILABLE)
rescue LoadError
  PG_AVAILABLE = false unless defined?(PG_AVAILABLE)
end

require_relative '../utils/database_helpers'
require_relative '../support/ui_helpers'
require_relative 'init_time_helpers'

# Manages source lifecycle: pause, resume, retire.
# Used by bin/manage_source.rb.
class SourceManager
  include Support::UiHelpers
  include SourceWizard::InitTimeHelpers

  def initialize(config_dir:, db_schema:)
    @config_dir = config_dir
    @db_schema = db_schema
  end

  # Dočasně pozastaví zdroj.
  # YAML: enabled: false + # paused_at / # paused_reason
  # DB: disabled_at = NOW()
  # @return [Boolean]
  def pause(source_id, reason: nil)
    yaml_path = source_yaml_path(source_id)
    return false unless validate_source_exists!(yaml_path, source_id)

    edit_yaml_pause(yaml_path, reason)

    with_db do |conn|
      conn.exec_params(
        'UPDATE source_state SET disabled_at = NOW(), updated_at = NOW() WHERE source_id = $1',
        [source_id]
      )
    end

    puts
    puts "  \u23F8  #{source_id}: pozastaveno"
    puts "     YAML:   #{yaml_path}"
    puts "     DB:     disabled_at = NOW()"
    puts "     Důvod:  #{reason || '(nezadán)'}"
    puts
    true
  end

  # Reaktivuje pozastavený zdroj.
  # YAML: enabled: true, odstraní pause komentáře
  # DB: disabled_at = NULL, error_count = 0, last_check = init_time
  # @return [Boolean]
  def resume(source_id)
    yaml_path = source_yaml_path(source_id)
    return false unless validate_source_exists!(yaml_path, source_id)

    edit_yaml_resume(yaml_path)

    puts
    puts '  Od kdy zpracovávat příspěvky po reaktivaci:'
    init_time = ask_init_time

    with_db do |conn|
      conn.exec_params(
        <<~SQL,
          UPDATE source_state
          SET disabled_at = NULL,
              error_count  = 0,
              last_error   = NULL,
              last_check   = $2,
              updated_at   = NOW()
          WHERE source_id = $1
        SQL
        [source_id, init_time]
      )
    end

    puts
    puts "  \u25B6  #{source_id}: reaktivováno"
    puts "     YAML:       #{yaml_path}"
    puts "     DB:         disabled_at = NULL"
    puts "     last_check: #{init_time.strftime('%Y-%m-%d %H:%M')}"
    puts
    true
  end

  # Trvale vyřadí zdroj (vždy vyžaduje interaktivní potvrzení).
  # YAML přesunut do config/sources/retired/
  # DB: source_state + published_posts smazány; activity_log zachován
  # @return [Boolean]
  def retire(source_id)
    yaml_path = source_yaml_path(source_id)
    return false unless validate_source_exists!(yaml_path, source_id)

    retired_dir  = File.join(@config_dir, 'sources', 'retired')
    retired_path = File.join(retired_dir, "#{source_id}.yml")

    puts
    puts "  \u{1F5D1}\uFE0F  Trvale vyřadit '#{source_id}'?"
    puts "     YAML → #{retired_path}"
    puts "     DB:   source_state + published_posts budou SMAZÁNY"
    puts "           activity_log zůstane zachován (historická data)"
    puts
    return false unless ask_yes_no('Potvrdit retire?', default: false)

    FileUtils.mkdir_p(retired_dir)
    FileUtils.mv(yaml_path, retired_path)

    with_db do |conn|
      conn.exec_params('DELETE FROM source_state    WHERE source_id = $1', [source_id])
      conn.exec_params('DELETE FROM published_posts WHERE source_id = $1', [source_id])
    end

    puts
    puts "  \u{1F5D1}\uFE0F  #{source_id}: vyřazeno"
    puts "     YAML: #{retired_path}"
    puts "     DB:   záznamy smazány"
    puts
    true
  end

  # Vrací hash se stavem zdroje nebo nil pokud YAML neexistuje.
  # @return [Hash, nil]
  def source_status(source_id)
    yaml_path = source_yaml_path(source_id)
    return nil unless File.exist?(yaml_path)

    content = File.read(yaml_path, encoding: 'UTF-8')
    enabled       = content.match?(/^enabled:\s*true/)
    paused_at     = content[/^#\s*paused_at:\s*(.+)$/, 1]&.strip
    paused_reason = content[/^#\s*paused_reason:\s*(.+)$/, 1]&.strip

    db_row = {}
    with_db do |conn|
      result = conn.exec_params(
        'SELECT disabled_at, error_count, last_check, last_success FROM source_state WHERE source_id = $1',
        [source_id]
      )
      if result.ntuples > 0
        r = result[0]
        db_row = {
          disabled_at:  r['disabled_at'],
          error_count:  r['error_count'].to_i,
          last_check:   r['last_check'],
          last_success: r['last_success']
        }
      end
    end

    { source_id: source_id, yaml_enabled: enabled, paused_at: paused_at, paused_reason: paused_reason }.merge(db_row)
  end

  # Vrátí pole statusů všech aktivních zdrojů (ne retired).
  # @return [Array<Hash>]
  def list_sources
    sources_dir = File.join(@config_dir, 'sources')
    return [] unless Dir.exist?(sources_dir)

    Dir.glob(File.join(sources_dir, '*.yml')).sort.map do |path|
      source_status(File.basename(path, '.yml'))
    end.compact
  end

  private

  def source_yaml_path(source_id)
    File.join(@config_dir, 'sources', "#{source_id}.yml")
  end

  def validate_source_exists!(yaml_path, source_id)
    return true if File.exist?(yaml_path)

    puts "  \u274C Source '#{source_id}' nenalezen: #{yaml_path}"
    false
  end

  # YAML pause: enabled: true → enabled: false + komentáře hned pod ním
  def edit_yaml_pause(yaml_path, reason)
    content = File.read(yaml_path, encoding: 'UTF-8')
    timestamp   = Time.now.strftime('%Y-%m-%d %H:%M')
    reason_line = reason ? "\n# paused_reason: #{reason}" : ''

    content = content.gsub(
      /^(enabled:\s*)true/,
      "\\1false\n# paused_at: #{timestamp}#{reason_line}"
    )

    File.write(yaml_path, content, encoding: 'UTF-8')
  end

  # YAML resume: enabled: false + pause komentáře → enabled: true
  def edit_yaml_resume(yaml_path)
    content = File.read(yaml_path, encoding: 'UTF-8')

    content = content.gsub(
      /^enabled:\s*false\n(?:#\s*paused_at:[^\n]*\n)?(?:#\s*paused_reason:[^\n]*\n)?/,
      "enabled: true\n"
    )

    File.write(yaml_path, content, encoding: 'UTF-8')
  end

  def get_db_connection
    if ENV['CLOUDRON_POSTGRESQL_URL']
      PG.connect(ENV['CLOUDRON_POSTGRESQL_URL'])
    elsif ENV['DATABASE_URL']
      PG.connect(ENV['DATABASE_URL'])
    else
      begin
        PG.connect(
          host:     ENV.fetch('ZPRAVOBOT_DB_HOST', 'localhost'),
          port:     ENV.fetch('ZPRAVOBOT_DB_PORT', 5432).to_i,
          dbname:   ENV.fetch('ZPRAVOBOT_DB_NAME', 'zpravobot'),
          user:     ENV.fetch('ZPRAVOBOT_DB_USER', 'zpravobot_app'),
          password: ENV['ZPRAVOBOT_DB_PASSWORD']
        )
      rescue PG::Error
        nil
      end
    end
  rescue PG::Error
    nil
  end

  def with_db
    return unless defined?(PG_AVAILABLE) && PG_AVAILABLE

    conn = get_db_connection
    unless conn
      puts '  ⚠️  Nelze se připojit k databázi — DB změny přeskočeny'
      return
    end

    begin
      DatabaseHelpers.validate_schema!(@db_schema)
      conn.exec("SET search_path TO #{@db_schema}")
      yield conn
    rescue PG::Error => e
      puts "  ⚠️  DB chyba: #{e.message}"
    ensure
      conn.close
    end
  end
end
