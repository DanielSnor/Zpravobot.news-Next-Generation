# frozen_string_literal: true

require_relative '../utils/database_helpers'

class SourceGenerator
  def show_preview(yaml_content, filepath)
    puts
    puts '─' * 60
    puts "  📄 Náhled: #{filepath}"
    puts '─' * 60
    puts
    puts yaml_content
    puts '─' * 60
  end

  def show_mastodon_account_preview
    puts
    puts '─' * 60
    puts "  📄 Přidám do: config/mastodon_accounts.yml"
    puts '─' * 60
    puts generate_mastodon_account_yaml
    puts '─' * 60
  end

  def show_db_init_preview(data)
    puts
    puts '─' * 60
    puts "  🗄️  Inicializace DB (schéma: #{@db_schema})"
    puts '─' * 60
    puts
    puts "  source_id:  #{data[:id]}"
    puts "  last_check: #{data[:init_time].strftime('%Y-%m-%d %H:%M:%S')}"
    puts
    puts '─' * 60
  end

  def save_all(filepath, yaml_content, data)
    # 1. Ulozit source YAML
    save_file(filepath, yaml_content)

    # 2. Pridat do mastodon_accounts.yml pokud novy ucet
    if @new_mastodon_account
      append_mastodon_account
    end

    # 3. Inicializovat source_state v databazi
    init_source_state(data[:id], data[:init_time])
  end

  def save_file(filepath, content)
    dir = File.dirname(filepath)
    FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
    File.write(filepath, content, encoding: 'UTF-8')
  end

  def append_mastodon_account
    path = File.join(@config_dir, 'mastodon_accounts.yml')

    # Vytvor soubor pokud neexistuje
    unless File.exist?(path)
      File.write(path, "# Mastodon účty pro ZBNW-NG\n# ⚠️ PŘIDAT DO .gitignore!\n", encoding: 'UTF-8')
    end

    File.open(path, 'a', encoding: 'UTF-8') do |f|
      f.write(generate_mastodon_account_yaml)
    end
  end

  # ============================================
  # Database Initialization
  # ============================================

  def init_source_state(source_id, init_time)
    unless PG_AVAILABLE
      puts "  ⚠️  PostgreSQL gem není dostupný - DB inicializace přeskočena"
      puts "     Spusť manuálně: ./bin/run_zbnw.rb --first-run --source #{source_id}"
      return
    end

    conn = get_db_connection
    unless conn
      puts "  ⚠️  Nelze se připojit k databázi - DB inicializace přeskočena"
      puts "     Spusť manuálně: ./bin/run_zbnw.rb --first-run --source #{source_id}"
      return
    end

    begin
      DatabaseHelpers.validate_schema!(@db_schema)
      conn.exec("SET search_path TO #{@db_schema}")

      conn.exec_params(
        <<~SQL,
          INSERT INTO source_state (source_id, last_check, last_success, posts_today, error_count)
          VALUES ($1, $2, $2, 0, 0)
          ON CONFLICT (source_id) DO UPDATE SET
            last_check = EXCLUDED.last_check,
            last_success = EXCLUDED.last_success,
            error_count = 0,
            last_error = NULL,
            updated_at = NOW()
        SQL
        [source_id, init_time]
      )

      puts "  ✅ DB: source_state inicializován (last_check: #{init_time.strftime('%Y-%m-%d %H:%M')})"
    rescue PG::Error => e
      puts "  ⚠️  DB chyba: #{e.message}"
      puts "     Spusť manuálně: ./bin/run_zbnw.rb --first-run --source #{source_id}"
    ensure
      conn&.close
    end
  end

  def get_db_connection
    if ENV['CLOUDRON_POSTGRESQL_URL']
      PG.connect(ENV['CLOUDRON_POSTGRESQL_URL'])
    elsif ENV['DATABASE_URL']
      PG.connect(ENV['DATABASE_URL'])
    else
      begin
        PG.connect(
          host: ENV.fetch('ZPRAVOBOT_DB_HOST', 'localhost'),
          port: ENV.fetch('ZPRAVOBOT_DB_PORT', 5432).to_i,
          dbname: ENV.fetch('ZPRAVOBOT_DB_NAME', 'zpravobot'),
          user: ENV.fetch('ZPRAVOBOT_DB_USER', 'zpravobot_app'),
          password: ENV['ZPRAVOBOT_DB_PASSWORD']
        )
      rescue PG::Error
        nil
      end
    end
  rescue PG::Error
    nil
  end

  def show_success(data, filepath)
    puts
    puts '✅ Konfigurace úspěšně uložena!'
    puts
    puts '  📁 Vytvořené soubory:'
    puts "     • #{filepath}"
    puts "     • config/mastodon_accounts.yml (aktualizováno)" if @new_mastodon_account
    puts

    test_flag = @test_mode ? ' --test' : ''

    puts '  💡 Další kroky:'
    puts "     1. Testuj: ./bin/run_zbnw.rb --source #{data[:id]} --dry-run#{test_flag}"
    puts "     2. Spusť:  ./bin/run_zbnw.rb --source #{data[:id]}#{test_flag}"
    show_profile_sync_hint = %w[twitter bluesky].include?(data[:platform]) ||
                              (data[:platform] == 'rss' && data[:rss_source_type] == 'facebook')
    if data[:profile_sync_enabled] && show_profile_sync_hint
      puts "     3. Sync profilu: ./bin/sync_profiles.rb --source #{data[:id]}#{test_flag}"
    end
    puts
  end

  # ============================================
  # Validation Helpers
  # ============================================

  def mastodon_account_exists?(account_id)
    accounts = load_all_mastodon_accounts
    accounts.key?(account_id)
  end

  def source_exists?(source_id)
    filepath = File.join(@config_dir, 'sources', "#{source_id}.yml")
    File.exist?(filepath)
  end

  def load_all_mastodon_accounts
    path = File.join(@config_dir, 'mastodon_accounts.yml')
    return {} unless File.exist?(path)

    content = File.read(path, encoding: 'UTF-8')
    data = YAML.safe_load(content, permitted_classes: [], permitted_symbols: [], aliases: true)
    return {} unless data.is_a?(Hash)
    data
  rescue StandardError => e
    warn "  ⚠️  Chyba při načítání mastodon_accounts.yml: #{e.message}"
    {}
  end

  def load_aggregator_accounts
    accounts = load_all_mastodon_accounts
    aggregators = accounts.map do |id, config|
      next unless config.is_a?(Hash) && config['aggregator'] == true
      { id: id, config: config }
    end.compact

    # Razeni: betabot vzdy prvni, ostatni abecedne
    aggregators.sort_by { |acc| acc[:id] == 'betabot' ? '' : acc[:id] }
  end
end
