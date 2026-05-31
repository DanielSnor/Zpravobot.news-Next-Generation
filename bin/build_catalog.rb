#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Build Catalog — generuje statický katalog zdrojů a uploaduje na Surfer
# ============================================================
#
# 1. Načte config + DB + instanci
# 2. DataAggregator.aggregate → záznamy
# 3. Renderer.render → tmp/catalog/{index.html,data.json,app.js,app.css}
# 4. Upload na Surfer přes Surfer API (PUT /api/files/<path>, Net::HTTP)
#
# Usage:
#   ruby bin/build_catalog.rb                 # build + upload na PRODUKCI (katalog.zpravobot.news)
#   ruby bin/build_catalog.rb --upload-test   # build + upload na TEST (katalog-test.zpravobot.news)
#   ruby bin/build_catalog.rb --no-upload     # jen build do tmp/catalog (lokální náhled)
#   ruby bin/build_catalog.rb --no-stubs      # bez per-účet sdílecích stubů (zdroj/<id>.html)
#   ruby bin/build_catalog.rb --output DIR    # vlastní build adresář
#   ruby bin/build_catalog.rb --test          # zpravobot_test DB schema
#
# Surfer URL katalogu — v config/global.yml (infrastructure.catalog_prod_url /
# catalog_test_url). Tokeny v env.sh:
#   SURFER_TOKEN      prod access token (právo zápisu)
#   SURFER_TEST_TOKEN test access token
#   SURFER_URL        volitelný env override prod URL z global.yml
#   SURFER_TEST_URL   volitelný env override test URL z global.yml
#
# Cron (Cloudron) — po zpravobot_stats.rb, týdně:
#   30 20 * * 0  cd /app/data/zbnw-ng && ruby bin/build_catalog.rb 2>&1 >> logs/catalog.log
#
# ============================================================

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'optparse'
require 'uri'
require 'net/http'

require 'config/config_loader'
require 'state/database_connection'
require 'stats/mastodon_stats'
require 'stats/snapshot_store'
require 'catalog/data_aggregator'
require 'catalog/renderer'

options = {
  upload: true,
  output: File.expand_path('../tmp/catalog', __dir__),
  test:   false,
  target: 'prod',  # 'prod' = katalog.zpravobot.news, 'test' = katalog-test.zpravobot.news
  stubs:  true     # generovat per-účet sdílecí HTML stuby (zdroj/<id>.html)
}

OptionParser.new do |opts|
  opts.banner = 'Usage: ruby bin/build_catalog.rb [options]'
  opts.on('--no-upload', 'Build only, do not upload to Surfer')          { options[:upload] = false }
  opts.on('--no-stubs', 'Skip per-account share stubs (zdroj/<id>.html)') { options[:stubs] = false }
  opts.on('--output DIR', 'Build output directory')                      { |v| options[:output] = File.expand_path(v) }
  opts.on('--test', 'Use zpravobot_test DB schema')                      { options[:test] = true }
  opts.on('--upload-test', 'Upload to katalog-test instance (test token)') { options[:target] = 'test' }
  opts.on('-h', '--help', 'Show this help') { puts opts; exit 0 }
end.parse!

def log(msg)
  $stdout.puts "[#{Time.now.strftime('%H:%M:%S')}] #{msg}"
  $stdout.flush
end

def die(msg, code: 3)
  $stderr.puts "ERROR: #{msg}"
  exit code
end

# Soubory, které se uploadují (pořadí: data → assety → HTML jako poslední,
# aby stránka nikdy nereferencovala data.json, který ještě neexistuje).
UPLOAD_FILES = %w[data.json app.css app.js header.jpg sitemap.xml robots.txt index.html].freeze

# ============================================================
# Step 1 — Config + DB
# ============================================================
config_dir = ENV.fetch('ZBNW_CONFIG_DIR',
               ENV['ZBNW_DIR'] ? "#{ENV['ZBNW_DIR']}/config" : 'config')
loader = Config::ConfigLoader.new(config_dir)
global = loader.load_global_config
instance = global.dig(:mastodon, :instance) || 'https://zpravobot.news'

# Veřejná URL katalogu (pro SEO/OG/canonical i jako cíl uploadu). Z global.yml
# (infrastructure.catalog_*_url), env SURFER_URL/SURFER_TEST_URL má přednost.
infra = global[:infrastructure] || {}
catalog_url = (if options[:target] == 'test'
                 ENV['SURFER_TEST_URL'] || infra[:catalog_test_url]
               else
                 ENV['SURFER_URL'] || infra[:catalog_prod_url]
               end).to_s.chomp('/')
log "Config: #{config_dir} | Instance: #{instance} | Katalog: #{catalog_url}"

db = State::DatabaseConnection.new(schema: options[:test] ? 'zpravobot_test' : nil)
begin
  db.connect
rescue StandardError => e
  die "DB connection failed: #{e.message}"
end
log "Connected to DB (schema: #{db.schema})"

# ============================================================
# Step 2 — Aggregate
# ============================================================
log 'Agreguji data ze tří zdrojů…'
agg = Catalog::DataAggregator.new(
  config_loader: loader,
  db: db,
  mastodon_instance: instance
)
records = agg.aggregate
db.disconnect

if records.empty?
  die 'Agregace vrátila 0 záznamů — kontrola configu (family vyplněna?). Upload zrušen.', code: 4
end
log "Záznamů: #{records.size}"

# ============================================================
# Step 3 — Render
# ============================================================
log "Renderuji do #{options[:output]}…"
written = Catalog::Renderer.new.render(
  records, output_dir: options[:output], site_url: catalog_url, account_stubs: options[:stubs]
)
written.each do |path|
  next if path.include?('/zdroj/')   # stuby logujeme souhrnně
  log "  → #{File.basename(path)} (#{File.size(path)} B)"
end
stub_count = written.count { |p| p.include?('/zdroj/') }
log "  → zdroj/ (#{stub_count} per-účet stubů)" if stub_count.positive?

unless options[:upload]
  log 'Build hotový. --no-upload, končím.'
  log "Lokální náhled: cd #{options[:output]} && python3 -m http.server"
  exit 0
end

# ============================================================
# Step 4 — Upload na Surfer (HTTP API)
# ============================================================
# Surfer access token se autentizuje proti Surfer API (/api/files/<path>),
# ne proti /_webdav (to chce Basic auth s Cloudron heslem). Token jde buď
# v hlavičce `Authorization: Bearer`, nebo jako `?access_token=` query param —
# posíláme obojí kvůli kompatibilitě napříč verzemi Surferu.
#
# Prod:              SURFER_TOKEN       + infrastructure.catalog_prod_url
# Test (--upload-test): SURFER_TEST_TOKEN + infrastructure.catalog_test_url
# surfer_base = catalog_url spočítané v Step 1 (z global.yml / env override).
# Token v env.sh: SURFER_TOKEN (prod) / SURFER_TEST_TOKEN (test).
surfer_base = catalog_url
if options[:target] == 'test'
  surfer_token = ENV['SURFER_TEST_TOKEN']
  token_var    = 'SURFER_TEST_TOKEN'
  url_key      = 'infrastructure.catalog_test_url'
else
  surfer_token = ENV['SURFER_TOKEN']
  token_var    = 'SURFER_TOKEN'
  url_key      = 'infrastructure.catalog_prod_url'
end
die "Chybí URL katalogu (global.yml #{url_key} nebo env override).", code: 2 if surfer_base.empty?
die "Chybí #{token_var} v prostředí (env.sh). Upload nelze provést.", code: 2 if surfer_token.to_s.empty?

log "Upload na #{surfer_base} (#{options[:target]}) …"

CONTENT_TYPES = {
  '.html' => 'text/html; charset=utf-8',
  '.json' => 'application/json; charset=utf-8',
  '.js'   => 'application/javascript; charset=utf-8',
  '.css'  => 'text/css; charset=utf-8',
  '.jpg'  => 'image/jpeg',
  '.jpeg' => 'image/jpeg',
  '.png'  => 'image/png'
}.freeze

# Surfer API očekává multipart/form-data s polem `file`. Cesta v URL určuje cíl,
# `overwrite=true` povolí přepis existujícího souboru.
def put_file(base, token, file_path, remote_name)
  uri = URI("#{base}/api/files/#{remote_name}")
  uri.query = URI.encode_www_form(access_token: token, newFilePath: remote_name)
  ext = File.extname(remote_name)

  boundary = "----ZbnwCatalog#{Time.now.to_i}#{rand(1_000_000)}"
  body = +''.dup.force_encoding('BINARY')
  body << "--#{boundary}\r\n"
  body << %(Content-Disposition: form-data; name="file"; filename="#{remote_name}"\r\n)
  body << "Content-Type: #{CONTENT_TYPES.fetch(ext, 'application/octet-stream')}\r\n\r\n"
  body << File.binread(file_path)
  body << "\r\n--#{boundary}--\r\n"

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == 'https')
  http.open_timeout = 10
  http.read_timeout = 30

  req = Net::HTTP::Post.new(uri)
  req['Authorization'] = "Bearer #{token}"
  req['Content-Type']  = "multipart/form-data; boundary=#{boundary}"
  req.body = body

  res = http.request(req)
  [res.code.to_i, res.message]
end

failures = []

# Core soubory — logované jednotlivě.
UPLOAD_FILES.each do |name|
  path = File.join(options[:output], name)
  unless File.exist?(path)
    failures << "#{name}: lokální soubor chybí"
    next
  end

  begin
    code, message = put_file(surfer_base, surfer_token, path, name)
    if (200..299).include?(code)
      log "  ✓ #{name} (HTTP #{code})"
    else
      failures << "#{name}: HTTP #{code} #{message}"
      log "  ✗ #{name} (HTTP #{code} #{message})"
    end
  rescue StandardError => e
    failures << "#{name}: #{e.class} #{e.message}"
    log "  ✗ #{name} (#{e.class} #{e.message})"
  end
end

# Per-účet stuby (zdroj/*.html) — můžou jich být stovky, logujeme souhrnně.
stub_paths = Dir.glob(File.join(options[:output], 'zdroj', '*.html')).sort
if stub_paths.any?
  stub_ok = 0
  stub_paths.each do |path|
    remote = "zdroj/#{File.basename(path)}"
    begin
      code, message = put_file(surfer_base, surfer_token, path, remote)
      if (200..299).include?(code)
        stub_ok += 1
      else
        failures << "#{remote}: HTTP #{code} #{message}"
      end
    rescue StandardError => e
      failures << "#{remote}: #{e.class} #{e.message}"
    end
  end
  log "  ✓ per-účet stuby: #{stub_ok}/#{stub_paths.size} nahráno"
end

if failures.empty?
  log "Hotovo. Katalog dostupný na #{surfer_base}/"
  exit 0
else
  $stderr.puts "ERROR: Upload selhal pro #{failures.size} souborů:"
  failures.each { |f| $stderr.puts "  - #{f}" }
  exit 1
end
