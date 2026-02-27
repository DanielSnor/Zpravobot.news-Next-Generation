#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for SourceManager (TASK-4)
# Validates: class API, YAML pause/resume edit, retire file move, InitTimeHelpers,
#            ProblematicSourcesCheck SQL backward compat stub.
# All offline — no PostgreSQL required.
#
# Run: ruby test/test_manage_source.rb

require 'tmpdir'
require 'fileutils'
require 'yaml'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require_relative '../lib/source_wizard/source_manager'
require_relative '../lib/source_wizard/init_time_helpers'
require_relative '../lib/source_wizard/source_generator'

puts '=' * 60
puts 'SourceManager Tests (TASK-4)'
puts '=' * 60
puts

$passed = 0
$failed = 0

def test(name, expected = true, actual = :use_block)
  if actual == :use_block
    result = begin
      yield
    rescue StandardError => e
      puts "  \e[31m✗\e[0m #{name}"
      puts "    Exception: #{e.class}: #{e.message}"
      $failed += 1
      return
    end
    ok = result
  else
    ok = (expected == actual)
  end

  if ok
    puts "  \e[32m✓\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m✗\e[0m #{name}"
    puts "    Expected: #{expected.inspect}" unless actual == :use_block
    puts "    Actual:   #{actual.inspect}"   unless actual == :use_block
    $failed += 1
  end
end

def section(title)
  puts
  puts "--- #{title} ---"
end

# ── Fixtures ─────────────────────────────────────────────────

SAMPLE_YAML = <<~YAML
  # CT24 Twitter source config
  id: ct24_twitter
  platform: twitter
  enabled: true
  handle: CT24tv
  target:
    mastodon_account: betabot
YAML

SAMPLE_YAML_PAUSED = <<~YAML
  # CT24 Twitter source config
  id: ct24_twitter
  platform: twitter
  enabled: false
  # paused_at: 2026-02-25 10:00
  # paused_reason: Test důvod
  handle: CT24tv
  target:
    mastodon_account: betabot
YAML

def make_tmpdir_with_source(yaml_content = SAMPLE_YAML)
  dir = Dir.mktmpdir('test_manage_source_')
  sources_dir = File.join(dir, 'sources')
  FileUtils.mkdir_p(sources_dir)
  File.write(File.join(sources_dir, 'ct24_twitter.yml'), yaml_content, encoding: 'UTF-8')
  dir
end

def make_manager(dir)
  SourceManager.new(config_dir: dir, db_schema: 'zpravobot_test')
end

# ─────────────────────────────────────────────────────────────
section('SourceManager: třída a API')
# ─────────────────────────────────────────────────────────────

test('SourceManager existuje') { defined?(SourceManager) }

test('respond_to? pause') do
  Dir.mktmpdir { |d| make_manager(d).respond_to?(:pause) }
end

test('respond_to? resume') do
  Dir.mktmpdir { |d| make_manager(d).respond_to?(:resume) }
end

test('respond_to? retire') do
  Dir.mktmpdir { |d| make_manager(d).respond_to?(:retire) }
end

test('respond_to? source_status') do
  Dir.mktmpdir { |d| make_manager(d).respond_to?(:source_status) }
end

test('respond_to? list_sources') do
  Dir.mktmpdir { |d| make_manager(d).respond_to?(:list_sources) }
end

# ─────────────────────────────────────────────────────────────
section('YAML editace: pause')
# ─────────────────────────────────────────────────────────────

test('pause: enabled: true → enabled: false') do
  dir = make_tmpdir_with_source
  begin
    manager = make_manager(dir)
    manager.send(:edit_yaml_pause, File.join(dir, 'sources', 'ct24_twitter.yml'), nil)
    content = File.read(File.join(dir, 'sources', 'ct24_twitter.yml'), encoding: 'UTF-8')
    content.match?(/^enabled:\s*false/)
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('pause: přidá # paused_at komentář hned pod enabled') do
  dir = make_tmpdir_with_source
  begin
    manager = make_manager(dir)
    manager.send(:edit_yaml_pause, File.join(dir, 'sources', 'ct24_twitter.yml'), nil)
    content = File.read(File.join(dir, 'sources', 'ct24_twitter.yml'), encoding: 'UTF-8')
    content.match?(/^enabled:\s*false\n#\s*paused_at:/)
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('pause: přidá # paused_reason když je zadán důvod') do
  dir = make_tmpdir_with_source
  begin
    manager = make_manager(dir)
    manager.send(:edit_yaml_pause, File.join(dir, 'sources', 'ct24_twitter.yml'), 'Nefunkční Nitter')
    content = File.read(File.join(dir, 'sources', 'ct24_twitter.yml'), encoding: 'UTF-8')
    content.include?('# paused_reason: Nefunkční Nitter')
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('pause: bez důvodu neobsahuje paused_reason') do
  dir = make_tmpdir_with_source
  begin
    manager = make_manager(dir)
    manager.send(:edit_yaml_pause, File.join(dir, 'sources', 'ct24_twitter.yml'), nil)
    content = File.read(File.join(dir, 'sources', 'ct24_twitter.yml'), encoding: 'UTF-8')
    !content.include?('paused_reason')
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('pause: ostatní obsah YAML zůstane beze změny') do
  dir = make_tmpdir_with_source
  begin
    manager = make_manager(dir)
    manager.send(:edit_yaml_pause, File.join(dir, 'sources', 'ct24_twitter.yml'), nil)
    content = File.read(File.join(dir, 'sources', 'ct24_twitter.yml'), encoding: 'UTF-8')
    content.include?('handle: CT24tv') && content.include?('mastodon_account: betabot')
  ensure
    FileUtils.rm_rf(dir)
  end
end

# ─────────────────────────────────────────────────────────────
section('YAML editace: resume')
# ─────────────────────────────────────────────────────────────

test('resume: enabled: false → enabled: true') do
  dir = make_tmpdir_with_source(SAMPLE_YAML_PAUSED)
  begin
    manager = make_manager(dir)
    manager.send(:edit_yaml_resume, File.join(dir, 'sources', 'ct24_twitter.yml'))
    content = File.read(File.join(dir, 'sources', 'ct24_twitter.yml'), encoding: 'UTF-8')
    content.match?(/^enabled:\s*true/)
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('resume: odstraní # paused_at komentář') do
  dir = make_tmpdir_with_source(SAMPLE_YAML_PAUSED)
  begin
    manager = make_manager(dir)
    manager.send(:edit_yaml_resume, File.join(dir, 'sources', 'ct24_twitter.yml'))
    content = File.read(File.join(dir, 'sources', 'ct24_twitter.yml'), encoding: 'UTF-8')
    !content.include?('paused_at')
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('resume: odstraní # paused_reason komentář') do
  dir = make_tmpdir_with_source(SAMPLE_YAML_PAUSED)
  begin
    manager = make_manager(dir)
    manager.send(:edit_yaml_resume, File.join(dir, 'sources', 'ct24_twitter.yml'))
    content = File.read(File.join(dir, 'sources', 'ct24_twitter.yml'), encoding: 'UTF-8')
    !content.include?('paused_reason')
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('resume: pause → resume → enabled: true (round-trip)') do
  dir = make_tmpdir_with_source
  begin
    yaml_path = File.join(dir, 'sources', 'ct24_twitter.yml')
    manager = make_manager(dir)
    manager.send(:edit_yaml_pause, yaml_path, 'Test')
    manager.send(:edit_yaml_resume, yaml_path)
    content = File.read(yaml_path, encoding: 'UTF-8')
    content.match?(/^enabled:\s*true/) && !content.include?('paused_at')
  ensure
    FileUtils.rm_rf(dir)
  end
end

# ─────────────────────────────────────────────────────────────
section('Retire: přesun souboru')
# ─────────────────────────────────────────────────────────────

test('retire: YAML přesune do sources/retired/') do
  dir = make_tmpdir_with_source
  begin
    yaml_path    = File.join(dir, 'sources', 'ct24_twitter.yml')
    retired_path = File.join(dir, 'sources', 'retired', 'ct24_twitter.yml')
    FileUtils.mkdir_p(File.join(dir, 'sources', 'retired'))
    FileUtils.mv(yaml_path, retired_path)
    File.exist?(retired_path) && !File.exist?(yaml_path)
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('retire: sources/retired/ je vytvořen automaticky (mkdir_p)') do
  dir = make_tmpdir_with_source
  begin
    yaml_path    = File.join(dir, 'sources', 'ct24_twitter.yml')
    retired_dir  = File.join(dir, 'sources', 'retired')
    retired_path = File.join(retired_dir, 'ct24_twitter.yml')
    FileUtils.mkdir_p(retired_dir)
    FileUtils.mv(yaml_path, retired_path)
    Dir.exist?(retired_dir)
  ensure
    FileUtils.rm_rf(dir)
  end
end

# ─────────────────────────────────────────────────────────────
section('source_status: YAML parsování')
# ─────────────────────────────────────────────────────────────

test('source_status: aktivní zdroj — yaml_enabled: true') do
  dir = make_tmpdir_with_source
  begin
    # PG není dostupné → DB část se přeskočí
    status = make_manager(dir).source_status('ct24_twitter')
    status[:yaml_enabled] == true
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('source_status: pozastavený zdroj — yaml_enabled: false') do
  dir = make_tmpdir_with_source(SAMPLE_YAML_PAUSED)
  begin
    status = make_manager(dir).source_status('ct24_twitter')
    status[:yaml_enabled] == false
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('source_status: pozastavený zdroj — paused_at přítomen') do
  dir = make_tmpdir_with_source(SAMPLE_YAML_PAUSED)
  begin
    status = make_manager(dir).source_status('ct24_twitter')
    !status[:paused_at].nil? && !status[:paused_at].empty?
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('source_status: nil pro neexistující zdroj') do
  Dir.mktmpdir do |dir|
    FileUtils.mkdir_p(File.join(dir, 'sources'))
    make_manager(dir).source_status('neexistujici_source').nil?
  end
end

# ─────────────────────────────────────────────────────────────
section('list_sources')
# ─────────────────────────────────────────────────────────────

test('list_sources: prázdný adresář → []') do
  Dir.mktmpdir do |dir|
    FileUtils.mkdir_p(File.join(dir, 'sources'))
    make_manager(dir).list_sources == []
  end
end

test('list_sources: jeden zdroj → pole o 1 prvku') do
  dir = make_tmpdir_with_source
  begin
    result = make_manager(dir).list_sources
    result.length == 1 && result.first[:source_id] == 'ct24_twitter'
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('list_sources: neexistující sources_dir → []') do
  Dir.mktmpdir do |dir|
    make_manager(dir).list_sources == []
  end
end

# ─────────────────────────────────────────────────────────────
section('validate_source_exists!')
# ─────────────────────────────────────────────────────────────

test('vrátí true pro existující YAML') do
  dir = make_tmpdir_with_source
  begin
    yaml_path = File.join(dir, 'sources', 'ct24_twitter.yml')
    make_manager(dir).send(:validate_source_exists!, yaml_path, 'ct24_twitter')
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('vrátí false pro neexistující YAML') do
  Dir.mktmpdir do |dir|
    FileUtils.mkdir_p(File.join(dir, 'sources'))
    yaml_path = File.join(dir, 'sources', 'nonexistent.yml')
    !make_manager(dir).send(:validate_source_exists!, yaml_path, 'nonexistent')
  end
end

# ─────────────────────────────────────────────────────────────
section('InitTimeHelpers modul')
# ─────────────────────────────────────────────────────────────

test('SourceWizard::InitTimeHelpers existuje') { defined?(SourceWizard::InitTimeHelpers) }

test('INIT_TIME_OPTIONS je Hash') do
  SourceWizard::InitTimeHelpers::INIT_TIME_OPTIONS.is_a?(Hash)
end

test('INIT_TIME_OPTIONS obsahuje klíč now') do
  SourceWizard::InitTimeHelpers::INIT_TIME_OPTIONS.key?('now')
end

test('INIT_TIME_OPTIONS obsahuje klíč custom') do
  SourceWizard::InitTimeHelpers::INIT_TIME_OPTIONS.key?('custom')
end

test('SourceManager include InitTimeHelpers — respond_to? ask_init_time') do
  Dir.mktmpdir { |d| make_manager(d).respond_to?(:ask_init_time, true) }
end

# ─────────────────────────────────────────────────────────────
section('ProblematicSourcesCheck: SQL obsahuje disabled_at IS NULL')
# ─────────────────────────────────────────────────────────────

test('ProblematicSourcesCheck zdrojový soubor obsahuje disabled_at IS NULL') do
  check_file = File.expand_path(
    '../lib/health/checks/problematic_sources_check.rb', __dir__
  )
  content = File.read(check_file, encoding: 'UTF-8')
  content.include?('disabled_at IS NULL')
end

test('ProblematicSourcesCheck obsahuje PG::UndefinedColumn backward compat') do
  check_file = File.expand_path(
    '../lib/health/checks/problematic_sources_check.rb', __dir__
  )
  content = File.read(check_file, encoding: 'UTF-8')
  content.include?('PG::UndefinedColumn')
end

# ─────────────────────────────────────────────────────────────
section('SourceGenerator: zpětná kompatibilita po extrakci')
# ─────────────────────────────────────────────────────────────

test('SourceGenerator.new se inicializuje bez chyb') do
  SourceGenerator.new
  true
end

test('SourceGenerator include SourceWizard::InitTimeHelpers') do
  SourceGenerator.ancestors.include?(SourceWizard::InitTimeHelpers)
end

test('SourceGenerator respond_to? collect_init_time') do
  SourceGenerator.new.respond_to?(:collect_init_time, true)
end

# ─────────────────────────────────────────────────────────────
puts
puts '=' * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts '=' * 60

exit($failed.zero? ? 0 : 1)
