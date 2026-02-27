# frozen_string_literal: true

require 'yaml'
require 'fileutils'
require 'net/http'
require 'json'
require 'time'

# PostgreSQL - volitelne (funguje i bez DB)
begin
  require 'pg'
  PG_AVAILABLE = true unless defined?(PG_AVAILABLE)
rescue LoadError
  PG_AVAILABLE = false unless defined?(PG_AVAILABLE)
end

# Load all parts of SourceGenerator (class reopening pattern)
require_relative 'init_time_helpers'
require_relative 'constants'
require_relative 'ui_helpers'
require_relative 'helpers'
require_relative 'data_collection'
require_relative 'display_name_fetcher'
require_relative 'yaml_generator'
require_relative 'persistence'

class SourceGenerator
  include SourceWizard::InitTimeHelpers

  def initialize(config_dir: nil, test_mode: false)
    @test_mode = test_mode || ARGV.include?('--test')
    @quick_mode = ARGV.include?('--quick')
    @new_mastodon_account = nil  # Uchovava data pro novy ucet

    # Urcit config_dir podle prostredi
    if config_dir
      @config_dir = config_dir
    elsif @test_mode
      @config_dir = ENV.fetch('ZBNW_CONFIG_DIR', ENV['ZBNW_DIR'] ? "#{ENV['ZBNW_DIR']}/config" : 'config')
    else
      @config_dir = ENV.fetch('ZBNW_CONFIG_DIR', ENV['ZBNW_DIR'] ? "#{ENV['ZBNW_DIR']}/config" : 'config')
    end

    # Schema databaze
    @db_schema = @test_mode ? 'zpravobot_test' : ENV.fetch('ZPRAVOBOT_SCHEMA', 'zpravobot')
  end

  def run
    puts
    puts "\u2550" * 60
    puts "  \u{1F4DD} ZBNW-NG Source Configuration Generator"
    puts "\u2550" * 60
    puts
    mode_info = []
    mode_info << 'QUICK' if @quick_mode
    mode_info << 'TEST' if @test_mode
    if mode_info.any?
      puts "  Re\u017eim: #{mode_info.join(' + ')}"
    else
      puts "  Re\u017eim: FULL (v\u0161echna nastaven\u00ed)"
    end
    puts "  Config: #{@config_dir}"
    puts "  DB sch\u00e9ma: #{@db_schema}"
    puts

    # Sbirame data
    data = collect_data

    # Generujeme YAML
    yaml_content = generate_yaml(data)
    filename = "#{data[:id]}.yml"
    filepath = File.join(@config_dir, 'sources', filename)

    # Nahled
    show_preview(yaml_content, filepath)

    # Nahled mastodon_accounts.yml pokud novy ucet
    if @new_mastodon_account
      show_mastodon_account_preview
    end

    # Nahled DB inicializace
    show_db_init_preview(data)

    # Potvrzeni a ulozeni
    if confirm_save(filepath)
      save_all(filepath, yaml_content, data)
      show_success(data, filepath)
    else
      puts
      puts "\u274c Zru\u0161eno u\u017eivatelem."
      puts
    end
  end
end
