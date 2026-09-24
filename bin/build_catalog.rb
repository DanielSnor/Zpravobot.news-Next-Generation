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
#   ruby bin/build_catalog.rb                 # plný build + upload na PRODUKCI (katalog.zpravobot.news)
#   ruby bin/build_catalog.rb --upload-test   # plný build + upload na TEST (katalog-test.zpravobot.news)
#   ruby bin/build_catalog.rb --posts-only    # JEN posts.json z Mastodon DB (účty z data.json) + upload posts.json
#   ruby bin/build_catalog.rb --web-only      # JEN frontend (index.html + app.js/css/obrázky), bez DB/data/postů/stubů
#   ruby bin/build_catalog.rb --no-upload     # jen build do tmp/catalog (lokální náhled)
#   ruby bin/build_catalog.rb --upload-only   # upload existujícího tmp/catalog (přeskočí build)
#   ruby bin/build_catalog.rb --no-stubs      # bez per-účet sdílecích stubů (zdroj/<id>.html)
#   ruby bin/build_catalog.rb --output DIR    # vlastní build adresář
#   ruby bin/build_catalog.rb --test          # zpravobot_test DB schema
#
# Surfer URL katalogu — v config/global.yml (infrastructure.catalog_prod_url /
# catalog_test_url). Tokeny v env.sh:
#   SURFER_TOKEN      prod access token (právo zápisu)
#   SURFER_TEST_TOKEN test access token
#   SURFER_URL / SURFER_TEST_URL   volitelný env override URL z global.yml
#
# Mastodon DB (pro posts.json) — ve stejné DB jako katalog (public schéma), takže
# se použije sdílené CLOUDRON_POSTGRESQL_URL spojení. Volitelné overridy:
#   MASTODON_DB_SCHEMA  schéma Mastodon tabulek (default 'public')
#   MASTODON_DB_URL     je-li Mastodon v jiné databázi clusteru (jinak netřeba)
#
# Cron (Cloudron):
#   # plný build (účty/web) — týdně po zpravobot_stats.rb
#   30 20 * * 0  cd /app/data/zbnw-ng && ruby bin/build_catalog.rb 2>&1 >> logs/catalog.log
#   # čerstvé posty — často (např. každou hodinu), levný SQL dotaz
#   17 * * * *   cd /app/data/zbnw-ng && ruby bin/build_catalog.rb --posts-only 2>&1 >> logs/catalog_posts.log
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
require 'json'
require 'fileutils'
require 'catalog/data_aggregator'
require 'catalog/posts_collector'
require 'catalog/renderer'

options = {
  upload: true,
  upload_only: false,
  posts_only: false,
  web_only:   false,
  output: File.expand_path('../tmp/catalog', __dir__),
  test:   false,
  target: 'prod',  # 'prod' = katalog.zpravobot.news, 'test' = katalog-test.zpravobot.news
  stubs:  true,    # generovat per-účet sdílecí HTML stuby (zdroj/<id>.html)
  posts:  true     # sbírat top příspěvky z Mastodon DB → posts.json
}

OptionParser.new do |opts|
  opts.banner = 'Usage: ruby bin/build_catalog.rb [options]'
  opts.on('--no-upload', 'Build only, do not upload to Surfer')          { options[:upload] = false }
  opts.on('--upload-only', 'Upload already-built tmp/catalog to Surfer (skip build)') { options[:upload_only] = true }
  opts.on('--posts-only', 'Jen posts.json z Mastodon DB (účty z existujícího data.json) + upload posts.json') { options[:posts_only] = true }
  opts.on('--web-only', 'Jen frontend: přerenderuj index.html + nahraj app.js/app.css/obrázky (bez DB, bez data/posts/stubů)') { options[:web_only] = true }
  opts.on('--no-stubs', 'Skip per-account share stubs (zdroj/<id>.html)') { options[:stubs] = false }
  opts.on('--no-posts', 'Skip Posty collection (no posts.json)')          { options[:posts] = false }
  opts.on('--output DIR', 'Build output directory')                      { |v| options[:output] = File.expand_path(v) }
  opts.on('--test', 'Use zpravobot_test DB schema')                      { options[:test] = true }
  opts.on('--upload-test', 'Upload to katalog-test instance (test token)') { options[:target] = 'test' }
  opts.on('-h', '--help', 'Show this help') { puts opts; exit 0 }
end.parse!
options[:posts] = true if options[:posts_only]   # posts-only vždy sbírá posty

def log(msg)
  $stdout.puts "[#{Time.now.strftime('%H:%M:%S')}] #{msg}"
  $stdout.flush
end

def die(msg, code: 3)
  $stderr.puts "ERROR: #{msg}"
  exit code
end

# Sběr top příspěvků z Mastodon DB → posts.json hash (nebo nil při chybě).
# Mastodon tabulky jsou ve stejné DB (public schéma) → reuse katalogového spojení;
# je-li Mastodon v jiné databázi clusteru, nastav MASTODON_DB_URL.
# Posty jsou doplněk — selhání vrací nil (volající rozhodne, zda fatální).
def collect_posts_json(records, instance, db)
  schema = ENV.fetch('MASTODON_DB_SCHEMA', 'public')
  db_url = ENV['MASTODON_DB_URL']
  conn   = db_url ? PG.connect(db_url) : db.conn
  log "Sbírám top příspěvky z Mastodon DB (schéma #{schema}#{db_url ? ', MASTODON_DB_URL' : ', sdílené spojení'})…"
  data = Catalog::PostsCollector.new(
    conn: conn, records: records, mastodon_schema: schema, instance_url: instance
  ).collect
  log "  posts.json: #{data['total_posts']} postů, " \
      "top engagement #{data['top_by_engagement'].first&.dig('engagement') || 0}"
  data
rescue StandardError => e
  log "  ⚠️  Sběr postů selhal (#{e.class}: #{e.message})"
  nil
ensure
  conn.close if db_url && conn
end

# Soubory, které se uploadují (pořadí: data → assety → HTML jako poslední,
# aby stránka nikdy nereferencovala data.json, který ještě neexistuje).
UPLOAD_FILES = %w[
  data.json app.css app.js
  header.jpg oscloud.png maskot.png
  card-account.png card-account-detail.png card-post.png daniel.jpg qr.jpg search-results.png
  sitemap.xml robots.txt index.html
].freeze

# Volitelné soubory — když chybí v build adresáři, jen se přeskočí (ne fail uploadu).
# Obrázky se kopírují jen pokud existují v šablonách (viz Renderer::IMAGE_ASSETS).
OPTIONAL_UPLOAD_FILES = %w[posts.json maskot.png].freeze

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
surfer_dir = (options[:target] == 'test' ? ENV.fetch('SURFER_TEST_DIR', '') : '').gsub(%r{^/+|/+$}, '')
catalog_url = "#{catalog_url}/#{surfer_dir}" unless surfer_dir.empty?
log "Config: #{config_dir} | Instance: #{instance} | Katalog: #{catalog_url}"

if options[:upload_only]
  die "tmp/catalog neexistuje — nejdřív spusť build (bez --upload-only)." unless Dir.exist?(options[:output])
  log "--upload-only: přeskakuji build, nahrávám #{options[:output]} → #{catalog_url}"
end

unless options[:upload_only]
if options[:web_only]
  # ============================================================
  # Web-only — jen frontend (index.html + assety), bez DB/agregace/postů/stubů
  # ============================================================
  data_json = File.join(options[:output], 'data.json')
  unless File.exist?(data_json)
    die "--web-only: chybí #{data_json} — nejdřív spusť plný build.", code: 4
  end
  records = JSON.parse(File.read(data_json, encoding: 'UTF-8'), symbolize_names: true)
  log "--web-only: načteno #{records.size} účtů z data.json (bez DB)"
  Catalog::Renderer.new.render(
    records, output_dir: options[:output], site_url: catalog_url,
    account_stubs: false, posts: nil
  )
  log '  → index.html + sitemap + robots + app.js/app.css/obrázky přerenderovány'
else
db = State::DatabaseConnection.new(schema: options[:test] ? 'zpravobot_test' : nil)
begin
  db.connect
rescue StandardError => e
  die "DB connection failed: #{e.message}"
end
log "Connected to DB (schema: #{db.schema})"

if options[:posts_only]
  # ============================================================
  # Posts-only — jen posts.json (účty z existujícího data.json, častý cron)
  # ============================================================
  data_json = File.join(options[:output], 'data.json')
  unless File.exist?(data_json)
    db.disconnect
    die "--posts-only: chybí #{data_json} — nejdřív spusť plný build.", code: 4
  end
  records = JSON.parse(File.read(data_json, encoding: 'UTF-8'), symbolize_names: true)
  log "--posts-only: načteno #{records.size} účtů z data.json"

  posts_data = collect_posts_json(records, instance, db)
  db.disconnect
  die 'Sběr postů selhal — posts.json nevznikl, upload zrušen.', code: 5 if posts_data.nil?

  FileUtils.mkdir_p(options[:output])
  File.write(File.join(options[:output], 'posts.json'), JSON.generate(posts_data))
  log "  → posts.json (#{posts_data['total_posts']} postů, #{File.size(File.join(options[:output], 'posts.json'))} B)"
else
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

  if records.empty?
    db.disconnect
    die 'Agregace vrátila 0 záznamů — kontrola configu (family vyplněna?). Upload zrušen.', code: 4
  end
  log "Záznamů: #{records.size}"

  # Step 2b — Posty: top příspěvky z Mastodon DB → posts.json
  posts_data = options[:posts] ? collect_posts_json(records, instance, db) : nil

  db.disconnect

  # ============================================================
  # Step 3 — Render
  # ============================================================
  log "Renderuji do #{options[:output]}…"
  written = Catalog::Renderer.new.render(
    records, output_dir: options[:output], site_url: catalog_url,
    account_stubs: options[:stubs], posts: posts_data
  )
  written.each do |path|
    next if path.include?('/zdroj/')   # stuby logujeme souhrnně
    log "  → #{File.basename(path)} (#{File.size(path)} B)"
  end
  stub_count = written.count { |p| p.include?('/zdroj/') }
  log "  → zdroj/ (#{stub_count} per-účet stubů)" if stub_count.positive?
end
end # if web_only / else (DB build)

unless options[:upload]
  log 'Build hotový. --no-upload, končím.'
  log "Lokální náhled: cd #{options[:output]} && python3 -m http.server"
  exit 0
end

end # unless upload_only

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
# surfer_base = Surfer API host (bez subdir). Token v env.sh: SURFER_TOKEN (prod) / SURFER_TEST_TOKEN (test).
if options[:target] == 'test'
  surfer_token = ENV['SURFER_TEST_TOKEN']
  token_var    = 'SURFER_TEST_TOKEN'
  url_key      = 'infrastructure.catalog_test_url'
else
  surfer_token = ENV['SURFER_TOKEN']
  token_var    = 'SURFER_TOKEN'
  url_key      = 'infrastructure.catalog_prod_url'
end
surfer_base = surfer_dir.empty? ? catalog_url : catalog_url.delete_suffix("/#{surfer_dir}")
die "Chybí URL katalogu (global.yml #{url_key} nebo env override).", code: 2 if catalog_url.empty?
die "Chybí #{token_var} v prostředí (env.sh). Upload nelze provést.", code: 2 if surfer_token.to_s.empty?

log "Upload na #{catalog_url} (#{options[:target]}) …"

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

# --posts-only nahrává jen posts.json (rychlý častý cron). Jinak vše;
# posts.json se přidá za data.json, jen když vznikl (lazy-fetch ve frontendu).
upload_files =
  if options[:posts_only]
    ['posts.json']
  elsif options[:web_only]
    # Jen statický frontend — bez data.json (data se nemění) a bez posts.json.
    UPLOAD_FILES.reject { |f| f == 'data.json' }
  else
    list = UPLOAD_FILES.dup
    if File.exist?(File.join(options[:output], 'posts.json'))
      list.insert(list.index('data.json') + 1, 'posts.json')
    end
    list
  end

# Core soubory — logované jednotlivě.
upload_files.each do |name|
  path = File.join(options[:output], name)
  unless File.exist?(path)
    # Volitelné soubory (posts.json, maskot.png) — chybí-li, jen přeskoč, nefailuj.
    if OPTIONAL_UPLOAD_FILES.include?(name)
      log "  – #{name} (přeskočeno, není v build adresáři)"
    else
      failures << "#{name}: lokální soubor chybí"
    end
    next
  end

  begin
    remote = surfer_dir.empty? ? name : "#{surfer_dir}/#{name}"
    code, message = put_file(surfer_base, surfer_token, path, remote)
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
# V --posts-only / --web-only stuby nenahráváme (měníme jen posts.json / frontend).
stub_paths = (options[:posts_only] || options[:web_only]) ? [] : Dir.glob(File.join(options[:output], 'zdroj', '*.html')).sort
if stub_paths.any?
  stub_ok = 0
  stub_paths.each do |path|
    remote = "#{surfer_dir.empty? ? '' : "#{surfer_dir}/"}zdroj/#{File.basename(path)}"
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
  log "Hotovo. Katalog dostupný na #{catalog_url}/"
  exit 0
else
  $stderr.puts "ERROR: Upload selhal pro #{failures.size} souborů:"
  failures.each { |f| $stderr.puts "  - #{f}" }
  exit 1
end
