#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for Reporting::SourceReporter (Phase 2)
# All offline — no network, no PostgreSQL required.
#
# Run: ruby test/test_source_report.rb

require 'tmpdir'
require 'fileutils'
require 'yaml'
require 'set'
require 'time'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require_relative '../lib/reporting/source_reporter'

puts '=' * 60
puts 'SourceReporter Tests (Phase 2)'
puts '=' * 60
puts

$passed = 0
$failed = 0

def test(name)
  result = begin
    yield
  rescue StandardError => e
    puts "  \e[31m✗\e[0m #{name}"
    puts "    Exception: #{e.class}: #{e.message}"
    puts e.backtrace.first(3).map { |l| "      #{l}" }.join("\n")
    $failed += 1
    return
  end

  if result
    puts "  \e[32m✓\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m✗\e[0m #{name}"
    $failed += 1
  end
end

def section(title)
  puts
  puts "--- #{title} ---"
end

# ── Fixtures ─────────────────────────────────────────────────

SAMPLE_ACCOUNTS = <<~YAML
  # Header comment
  betabot:
    token: "t0"
    aggregator: true
    categories: [test]

  aktualnecz:
    token: "t1"
    aggregator: false
    categories: [news, politics]

  ct24:
    token: "t2"
    aggregator: false
    categories: [news, politics]

  sportcz:
    token: "t3"
    aggregator: false
    categories: [sport]
YAML

SNAPSHOT_CONTENT = <<~YAML
  # Automaticky generováno
  last_run: "2026-03-22T10:00:00+02:00"
  accounts:
    - aktualnecz
    - ct24
YAML

def make_reporter(accounts_content: SAMPLE_ACCOUNTS, snapshot_content: SNAPSHOT_CONTENT,
                  publisher: nil, dry_run: true)
  dir = Dir.mktmpdir('test_source_reporter_')
  accounts_file  = File.join(dir, 'mastodon_accounts.yml')
  snapshot_path  = File.join(dir, 'snapshot.yml')

  File.write(accounts_file,  accounts_content, encoding: 'UTF-8')
  File.write(snapshot_path,  snapshot_content, encoding: 'UTF-8') if snapshot_content

  reporter = Reporting::SourceReporter.new(
    accounts_file:    accounts_file,
    snapshot_path:    snapshot_path,
    publisher:        publisher,
    dry_run:          dry_run,
    default_instance: 'zpravobot.news'
  )

  [reporter, dir, accounts_file, snapshot_path]
end

# ─────────────────────────────────────────────────────────────
section('load_accounts')
# ─────────────────────────────────────────────────────────────

test('load_accounts: vrátí hash s account IDs') do
  reporter, dir, = make_reporter
  begin
    accounts = reporter.load_accounts
    accounts.key?('aktualnecz') && accounts.key?('ct24') && accounts.key?('betabot')
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('load_accounts: parsuje categories') do
  reporter, dir, = make_reporter
  begin
    accounts = reporter.load_accounts
    accounts['aktualnecz'][:categories] == %w[news politics]
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('load_accounts: ignoruje komentáře') do
  reporter, dir, = make_reporter
  begin
    accounts = reporter.load_accounts
    !accounts.key?('# Header comment')
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('load_accounts: instance nil pokud není definována') do
  reporter, dir, = make_reporter
  begin
    accounts = reporter.load_accounts
    accounts['aktualnecz'][:instance].nil?
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('load_accounts: parsuje instance URL (jen hostname)') do
  content = "mybot:\n  token: \"x\"\n  instance: \"https://mastodon.social\"\n  categories: [test]\n"
  reporter, dir, = make_reporter(accounts_content: content)
  begin
    accounts = reporter.load_accounts
    accounts['mybot'][:instance] == 'mastodon.social'
  ensure
    FileUtils.rm_rf(dir)
  end
end

# ─────────────────────────────────────────────────────────────
section('load_snapshot / save_snapshot')
# ─────────────────────────────────────────────────────────────

test('load_snapshot: vrátí pole account IDs') do
  reporter, dir, = make_reporter
  begin
    snap = reporter.load_snapshot
    snap.is_a?(Array) && snap.include?('aktualnecz') && snap.include?('ct24')
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('load_snapshot: vrátí nil pokud soubor neexistuje') do
  reporter, dir, = make_reporter(snapshot_content: nil)
  begin
    reporter.load_snapshot.nil?
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('load_snapshot: vrátí nil pro poškozený soubor') do
  reporter, dir, _, snapshot_path = make_reporter
  begin
    File.write(snapshot_path, "not: valid: yaml: :\n  - broken", encoding: 'UTF-8')
    reporter.load_snapshot.nil?
  rescue StandardError
    true  # expected
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('save_snapshot: zapíše soubor s account IDs') do
  reporter, dir, _, snapshot_path = make_reporter(dry_run: false)
  begin
    reporter.send(:save_snapshot, %w[foo bar baz])
    content = File.read(snapshot_path, encoding: 'UTF-8')
    content.include?('- foo') && content.include?('- bar') && content.include?('- baz')
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('save_snapshot: dry_run nepíše soubor') do
  dir = Dir.mktmpdir('test_dry_run_')
  begin
    accounts_file = File.join(dir, 'accounts.yml')
    snapshot_path = File.join(dir, 'snapshot.yml')
    File.write(accounts_file, SAMPLE_ACCOUNTS, encoding: 'UTF-8')

    reporter = Reporting::SourceReporter.new(
      accounts_file:    accounts_file,
      snapshot_path:    snapshot_path,
      dry_run:          true,
      default_instance: 'zpravobot.news'
    )
    reporter.send(:save_snapshot, %w[foo])
    !File.exist?(snapshot_path)
  ensure
    FileUtils.rm_rf(dir)
  end
end

# ─────────────────────────────────────────────────────────────
section('Detekce změn')
# ─────────────────────────────────────────────────────────────

test('run: detekuje nový účet (sportcz není v snapshotu)') do
  # Snapshot: aktualnecz, ct24 — aktuální accounts: + sportcz
  published_posts = []
  fake_publisher = Object.new
  fake_publisher.define_singleton_method(:publish) do |text, **_opts|
    published_posts << text
    { 'id' => '123', 'url' => 'https://zpravobot.news/@zpravobot/123' }
  end

  reporter, dir, = make_reporter(publisher: fake_publisher, dry_run: false)
  begin
    reporter.run
    published_posts.any? { |p| p.include?('sportcz') }
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('run: žádné změny → žádný post') do
  # Snapshot = aktuální stav (aktualnecz, ct24, sportcz, betabot)
  snap = "last_run: \"2026-03-22T10:00:00+02:00\"\naccounts:\n  - aktualnecz\n  - betabot\n  - ct24\n  - sportcz\n"
  published_posts = []
  fake_publisher = Object.new
  fake_publisher.define_singleton_method(:publish) do |text, **_opts|
    published_posts << text
    { 'id' => '1', 'url' => '' }
  end

  reporter, dir, = make_reporter(snapshot_content: snap, publisher: fake_publisher, dry_run: false)
  begin
    reporter.run
    published_posts.empty?
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('run: detekuje smazaný účet (starybot byl v snapshotu, není v accounts)') do
  snap = "last_run: \"2026-03-22T10:00:00+02:00\"\naccounts:\n  - aktualnecz\n  - ct24\n  - sportcz\n  - starybot\n"
  published_posts = []
  fake_publisher = Object.new
  fake_publisher.define_singleton_method(:publish) do |text, **_opts|
    published_posts << text
    { 'id' => '2', 'url' => '' }
  end

  reporter, dir, = make_reporter(snapshot_content: snap, publisher: fake_publisher, dry_run: false)
  begin
    reporter.run
    published_posts.any? { |p| p.include?('starybot') }
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('run: excluded accounts (betabot) jsou ignorovány') do
  # Snapshot bez betabot — betabot by měl být ignorován
  snap = "last_run: \"2026-03-22T10:00:00+02:00\"\naccounts:\n  - aktualnecz\n  - ct24\n  - sportcz\n"
  published_posts = []
  fake_publisher = Object.new
  fake_publisher.define_singleton_method(:publish) do |text, **_opts|
    published_posts << text
    { 'id' => '3', 'url' => '' }
  end

  reporter, dir, = make_reporter(snapshot_content: snap, publisher: fake_publisher, dry_run: false)
  begin
    reporter.run
    # betabot by neměl být v žádném postu
    published_posts.none? { |p| p.include?('betabot') }
  ensure
    FileUtils.rm_rf(dir)
  end
end

# ─────────────────────────────────────────────────────────────
section('Formátování postů — nové účty')
# ─────────────────────────────────────────────────────────────

test('format_new_posts: obsahuje mention nového účtu') do
  reporter, dir, = make_reporter
  begin
    accounts = reporter.load_accounts
    posts = reporter.format_new_posts(['sportcz'], accounts)
    posts.any? { |p| p.include?('@sportcz@zpravobot.news') }
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('format_new_posts: obsahuje kategorii') do
  reporter, dir, = make_reporter
  begin
    accounts = reporter.load_accounts
    posts = reporter.format_new_posts(['sportcz'], accounts)
    posts.any? { |p| p.include?('sport:') }
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('format_new_posts: obsahuje #newbots hashtag') do
  reporter, dir, = make_reporter
  begin
    accounts = reporter.load_accounts
    posts = reporter.format_new_posts(['sportcz'], accounts)
    posts.any? { |p| p.include?('#newbots') }
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('format_new_posts: singular intro pro 1 účet') do
  reporter, dir, = make_reporter
  begin
    accounts = reporter.load_accounts
    posts = reporter.format_new_posts(['sportcz'], accounts)
    intro = Reporting::SourceReporter::INTROS_NEW_SINGULAR
    posts.first && intro.any? { |i| posts.first.include?(i) }
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('format_new_posts: plural intro pro více účtů') do
  reporter, dir, = make_reporter
  begin
    accounts = reporter.load_accounts
    posts = reporter.format_new_posts(%w[sportcz aktualnecz], accounts)
    intro = Reporting::SourceReporter::INTROS_NEW_PLURAL
    posts.first && intro.any? { |i| posts.first.include?(i) }
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('format_new_posts: seskupuje podle první kategorie') do
  # sportcz → sport, aktualnecz → news
  reporter, dir, = make_reporter
  begin
    accounts = reporter.load_accounts
    posts = reporter.format_new_posts(%w[sportcz aktualnecz], accounts)
    text = posts.join("\n")
    text.include?('news:') && text.include?('sport:')
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('format_new_posts: účet bez kategorií → ostatní') do
  content = "nocat:\n  token: \"x\"\n  categories: []\n"
  reporter, dir, = make_reporter(accounts_content: content)
  begin
    accounts = reporter.load_accounts
    posts = reporter.format_new_posts(['nocat'], accounts)
    posts.any? { |p| p.include?('ostatní:') }
  ensure
    FileUtils.rm_rf(dir)
  end
end

# ─────────────────────────────────────────────────────────────
section('Formátování postů — smazané účty')
# ─────────────────────────────────────────────────────────────

test('format_deleted_posts: obsahuje mention smazaného účtu') do
  reporter, dir, = make_reporter
  begin
    posts = reporter.format_deleted_posts(['starybot'])
    posts.any? { |p| p.include?('@starybot@zpravobot.news') }
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('format_deleted_posts: obsahuje #deletedbots hashtag') do
  reporter, dir, = make_reporter
  begin
    posts = reporter.format_deleted_posts(['starybot'])
    posts.any? { |p| p.include?('#deletedbots') }
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('format_deleted_posts: singular intro pro 1 účet') do
  reporter, dir, = make_reporter
  begin
    posts = reporter.format_deleted_posts(['starybot'])
    intro = Reporting::SourceReporter::INTROS_DELETED_SINGULAR
    intro.any? { |i| posts.first.include?(i) }
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('format_deleted_posts: plural intro pro více účtů') do
  reporter, dir, = make_reporter
  begin
    posts = reporter.format_deleted_posts(%w[starybot jinybot])
    intro = Reporting::SourceReporter::INTROS_DELETED_PLURAL
    intro.any? { |i| posts.first.include?(i) }
  ensure
    FileUtils.rm_rf(dir)
  end
end

# ─────────────────────────────────────────────────────────────
section('Split na více postů')
# ─────────────────────────────────────────────────────────────

test('build_thread: krátký text → 1 post') do
  reporter, dir, = make_reporter
  begin
    posts = reporter.send(:build_thread, 'Intro', ['• @foo@zpravobot.news'], "\n\n#zpravobot")
    posts.size == 1
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('build_thread: dlouhý seznam → více postů') do
  reporter, dir, = make_reporter
  begin
    # 60 řádků po 10 znacích = ~600 znaků → musí se rozdělit
    lines = (1..60).map { |i| "• @bot#{i.to_s.rjust(3, '0')}@zpravobot.news" }
    posts = reporter.send(:build_thread, 'Intro', lines, "\n\n#zpravobot #newbots")
    posts.size > 1
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('build_thread: každý post ≤ MASTODON_CHAR_LIMIT') do
  reporter, dir, = make_reporter
  begin
    lines = (1..60).map { |i| "• @bot#{i.to_s.rjust(3, '0')}@zpravobot.news" }
    posts = reporter.send(:build_thread, 'Intro', lines, "\n\n#zpravobot #newbots")
    limit = Reporting::SourceReporter::MASTODON_CHAR_LIMIT
    posts.all? { |p| p.length <= limit }
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('build_thread: intro pouze v prvním postu') do
  reporter, dir, = make_reporter
  begin
    lines = (1..60).map { |i| "• @bot#{i.to_s.rjust(3, '0')}@zpravobot.news" }
    posts = reporter.send(:build_thread, 'MůjIntro', lines, "\n\n#zpravobot #newbots")
    posts.first.include?('MůjIntro') && posts.size > 1 && !posts[1].include?('MůjIntro')
  ensure
    FileUtils.rm_rf(dir)
  end
end

# ─────────────────────────────────────────────────────────────
section('--init a snapshot aktualizace')
# ─────────────────────────────────────────────────────────────

test('init: vytvoří snapshot bez postování') do
  published_posts = []
  fake_publisher = Object.new
  fake_publisher.define_singleton_method(:publish) do |text, **_opts|
    published_posts << text
    { 'id' => '1', 'url' => '' }
  end

  reporter, dir, _, snapshot_path = make_reporter(
    snapshot_content: nil,
    publisher: fake_publisher,
    dry_run: false
  )
  begin
    reporter.init
    snap = YAML.safe_load(File.read(snapshot_path, encoding: 'UTF-8'))
    published_posts.empty? && snap['accounts'].is_a?(Array)
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('run: snapshot se aktualizuje po úspěšném postu') do
  snap = "last_run: \"2026-03-22T10:00:00+02:00\"\naccounts:\n  - aktualnecz\n  - ct24\n"
  fake_publisher = Object.new
  fake_publisher.define_singleton_method(:publish) { |*| { 'id' => '9', 'url' => '' } }

  reporter, dir, _, snapshot_path = make_reporter(
    snapshot_content: snap,
    publisher:        fake_publisher,
    dry_run:          false
  )
  begin
    reporter.run
    new_snap = YAML.safe_load(File.read(snapshot_path, encoding: 'UTF-8'))
    new_snap['accounts'].include?('sportcz')
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('run: chybějící snapshot → inicializuje bez postu') do
  published_posts = []
  fake_publisher = Object.new
  fake_publisher.define_singleton_method(:publish) do |text, **_opts|
    published_posts << text
    { 'id' => '1', 'url' => '' }
  end

  reporter, dir, _, snapshot_path = make_reporter(
    snapshot_content: nil,
    publisher:        fake_publisher,
    dry_run:          false
  )
  begin
    reporter.run
    published_posts.empty? && File.exist?(snapshot_path)
  ensure
    FileUtils.rm_rf(dir)
  end
end

test('run: dry-run neaktualizuje snapshot') do
  snap_before = "last_run: \"2026-03-22T10:00:00+02:00\"\naccounts:\n  - aktualnecz\n  - ct24\n"
  reporter, dir, _, snapshot_path = make_reporter(
    snapshot_content: snap_before,
    dry_run:          true
  )
  begin
    reporter.run
    content_after = File.read(snapshot_path, encoding: 'UTF-8')
    content_after == snap_before
  ensure
    FileUtils.rm_rf(dir)
  end
end

# ─────────────────────────────────────────────────────────────
puts
puts '=' * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts '=' * 60

exit($failed.zero? ? 0 : 1)
