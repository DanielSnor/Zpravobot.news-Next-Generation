# frozen_string_literal: true

require 'yaml'
require 'fileutils'
require 'time'
require 'shellwords'

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
  # Po retire: nabídne cleanup záznamu v mastodon_accounts.yml
  # @return [Boolean]
  def retire(source_id)
    yaml_path = source_yaml_path(source_id)
    return false unless validate_source_exists!(yaml_path, source_id)

    # Přečíst mastodon_account před přesunutím YAML
    source_content   = File.read(yaml_path, encoding: 'UTF-8')
    mastodon_account = source_content[/^\s*mastodon_account:\s*(.+)$/, 1]&.strip

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
      conn.exec_params('DELETE FROM source_state       WHERE source_id = $1', [source_id])
      conn.exec_params('DELETE FROM published_posts    WHERE source_id = $1', [source_id])
      conn.exec_params('DELETE FROM media_fingerprints WHERE source_id = $1', [source_id])
    end

    puts
    puts "  \u{1F5D1}\uFE0F  #{source_id}: vyřazeno"
    puts "     YAML: #{retired_path}"
    puts "     DB:   záznamy smazány"
    puts

    # Cleanup mastodon_accounts.yml
    cleanup_mastodon_account_after_retire(mastodon_account, source_id) if mastodon_account

    puts "  \u26A0\uFE0F  Nezapomeň disablovat Mastodon účet na instanci!"
    puts
    true
  end

  # Vypíše přehled všech aktuálně pauzovaných zdrojů.
  # @return [void]
  def print_paused_status
    paused = list_sources.select { |s| !s[:yaml_enabled] || s[:disabled_at] }

    if paused.empty?
      puts '  ✅ Žádné pauzované zdroje.'
      puts
      return
    end

    puts "  ⏸  Pauzované zdroje (#{paused.length}):"
    puts
    puts "    #{'Zdroj'.ljust(32)} #{'Pauzováno'.ljust(17)} Důvod"
    puts "    #{('─' * 31)} #{('─' * 16)} #{('─' * 25)}"

    paused.each do |s|
      paused_when = s[:paused_at] || (s[:disabled_at] ? s[:disabled_at].to_s[0, 16] : '?')
      reason      = s[:paused_reason] || '(nezadán)'
      puts "    ⏸ #{s[:source_id].ljust(32)} #{paused_when.ljust(17)} #{reason}"
      puts "      └ last_error: #{s[:last_error]}" if s[:last_error] && !s[:last_error].to_s.empty?
    end
    puts
  end

  # Spustí probe pro všechny aktuálně pauzované zdroje.
  # @return [Boolean]
  def probe_all_paused
    paused = list_sources.select { |s| !s[:yaml_enabled] || s[:disabled_at] }

    if paused.empty?
      puts '  ✅ Žádné pauzované zdroje k prověření.'
      puts
      return true
    end

    puts "  🔍 Prověřuji #{paused.length} pauzovaný(ch) zdrojů..."

    paused.each_with_index do |s, i|
      puts
      puts "═ [#{i + 1}/#{paused.length}] #{s[:source_id]} #{'═' * [0, 54 - s[:source_id].length].max}"
      probe(s[:source_id])
    end

    puts '═' * 60
    puts '  Probe dokončen pro všechny pauzované zdroje.'
    puts
    true
  end

  # Ověří, zda je pauznutý zdroj zpět, bez jeho reaktivace.
  # Spustí dry-run přes orchestrátor a ukáže kolik příspěvků se načetlo.
  # Pokud zdroj vrací příspěvky, nabídne okamžitou reaktivaci.
  # @return [Boolean]
  def probe(source_id)
    yaml_path = source_yaml_path(source_id)
    return false unless validate_source_exists!(yaml_path, source_id)

    # Zobraz aktuální stav
    status = source_status(source_id)
    puts
    puts "  📋 Stav zdroje '#{source_id}':"
    puts "     Pozastaveno:    #{status[:disabled_at]}"     if status[:disabled_at]
    puts "     Paused at:      #{status[:paused_at]}"       if status[:paused_at]
    puts "     Důvod:          #{status[:paused_reason]}"   if status[:paused_reason]
    puts "     Poslední chyba: #{status[:last_error]}"      if status[:last_error]
    puts "     error_count:    #{status[:error_count]}"
    puts "     last_check:     #{status[:last_check]  || 'N/A'}"
    puts "     last_success:   #{status[:last_success] || 'N/A'}"
    puts

    # Spusť dry-run přes run_zbnw.rb
    project_dir = File.expand_path('../../../', __FILE__)
    runner      = File.join(project_dir, 'bin', 'run_zbnw.rb')

    unless File.exist?(runner)
      puts "  ❌ run_zbnw.rb nenalezen: #{runner}"
      return false
    end

    use_bundler = File.exist?(File.join(project_dir, 'Gemfile'))
    ruby_cmd    = use_bundler ? 'bundle exec ruby' : RbConfig.ruby.shellescape
    cmd = "cd #{project_dir.shellescape} && #{ruby_cmd} bin/run_zbnw.rb" \
          " --source #{source_id.shellescape} --dry-run --schema #{@db_schema.shellescape} 2>&1"

    puts "  🔍 Spouštím dry-run probe..."
    puts '─' * 60

    output = `#{cmd}`
    cmd_success = $?.success?

    puts output
    puts '─' * 60
    puts

    unless cmd_success
      puts "  ❌ Probe selhalo (exit #{$?.exitstatus})"
      puts "     Tip: jiný cron běh může držet lockfile — zkuste za chvíli."
      return false
    end

    # Parsuj počet načtených příspěvků ze stdout logu:
    # "[HH:MM:SS] ℹ️  [source_id] Fetched N posts"
    fetched = output.scan(/\[#{Regexp.escape(source_id)}\] Fetched (\d+)/).flatten.map(&:to_i).sum
    has_error = output.match?(/\[#{Regexp.escape(source_id)}\] Error:/)

    if has_error
      puts "  ❌ Zdroj stále hlásí chyby — ještě není zpět."
      return false
    elsif fetched > 0
      puts "  ✅ Zdroj je zpět — dry-run nalezl #{fetched} příspěvků."
      puts
      if ask_yes_no('  Reaktivovat zdroj nyní?', default: true)
        puts
        return resume(source_id)
      end
      return true
    else
      puts "  ⚠️  Probe proběhl bez chyb, ale zatím žádné nové příspěvky."
      puts "     Pokud jsi přesvědčen, že je zdroj funkční, reaktivuj ručně."
      puts
      if ask_yes_no('  Přesto reaktivovat?', default: false)
        puts
        return resume(source_id)
      end
      return true
    end
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

    Dir.glob(File.join(sources_dir, '*.yml')).sort.filter_map do |path|
      source_status(File.basename(path, '.yml'))
    end
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

  def mastodon_accounts_path
    File.join(@config_dir, 'mastodon_accounts.yml')
  end

  # Vrátí pole source IDs, které sdílejí stejný mastodon_account (kromě retire-ovaného zdroje).
  def other_sources_for_account(account_id, exclude_source_id)
    sources_dir = File.join(@config_dir, 'sources')
    return [] unless Dir.exist?(sources_dir)

    Dir.glob(File.join(sources_dir, '*.yml')).filter_map do |path|
      src_id = File.basename(path, '.yml')
      next if src_id == exclude_source_id

      content = begin
        File.read(path, encoding: 'UTF-8')
      rescue StandardError
        next
      end
      src_id if content.match?(/^\s*mastodon_account:\s*#{Regexp.escape(account_id)}\s*$/)
    end
  end

  # Po retire: zkontroluje, zda má účet jiné zdroje, a nabídne smazání z mastodon_accounts.yml.
  def cleanup_mastodon_account_after_retire(account_id, retired_source_id)
    others = other_sources_for_account(account_id, retired_source_id)

    if others.empty?
      puts "  \u{1F5D1}\uFE0F  Mastodon účet '#{account_id}' nemá žádné další zdroje."
      if ask_yes_no("     Smazat z mastodon_accounts.yml?", default: false)
        remove_from_mastodon_accounts(account_id)
      end
      puts
    else
      count = others.size
      label = count == 1 ? 'aktivní zdroj' : 'aktivní zdroje'
      puts "  \u2139\uFE0F  Mastodon účet '#{account_id}' má ještě #{count} #{label}:"
      others.each { |s| puts "     \u2022 #{s}" }
      puts "     Záznam v mastodon_accounts.yml ponechán."
      puts
    end
  end

  # Smaže blok account_id z mastodon_accounts.yml (text-based, zachová komentáře a formátování).
  def remove_from_mastodon_accounts(account_id)
    path = mastodon_accounts_path
    unless File.exist?(path)
      puts "  \u26A0\uFE0F  mastodon_accounts.yml nenalezen: #{path}"
      return
    end

    content = File.read(path, encoding: 'UTF-8')
    # Smazat blok: volitelný předcházející newline, řádek account_id: a všechny odsazené řádky
    new_content = content.sub(
      /\n?^#{Regexp.escape(account_id)}:\n(?:[ \t][^\n]*\n)*/m,
      ''
    )

    if new_content == content
      puts "  \u26A0\uFE0F  Záznam '#{account_id}' v mastodon_accounts.yml nenalezen"
      return
    end

    File.write(path, new_content, encoding: 'UTF-8')
    puts "  \u2705  '#{account_id}' smazán z mastodon_accounts.yml"
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
