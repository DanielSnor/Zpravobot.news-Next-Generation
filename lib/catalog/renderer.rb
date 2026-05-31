# frozen_string_literal: true

require 'erb'
require 'json'
require 'cgi'
require 'date'
require 'fileutils'
require_relative '../support/loggable'

module Catalog
  # Vyrobí statické soubory katalogu z agregovaných záznamů:
  #
  #   index.html  — layout (ERB), prázdný container pro karty
  #   data.json   — pole záznamů, fetchnuté JS-em po načtení
  #   app.js      — vanilla JS: filtrování, vyhledávání, render karet
  #   app.css     — styly
  #
  # data.json je samostatný (ne inline) kvůli cache-friendly rebuildu —
  # při změně dat se nemusí sahat na HTML/CSS/JS.
  #
  # Usage:
  #   Catalog::Renderer.new.render(records, output_dir: 'tmp/catalog')
  #
  class Renderer
    include Support::Loggable

    TEMPLATE_DIR = File.expand_path('templates', __dir__)
    STATIC_ASSETS = %w[app.js app.css].freeze
    IMAGE_ASSETS  = %w[header.jpg].freeze   # binární — kopírují se beze změny
    MAIN_ACCOUNT = '@zpravobot@zpravobot.news'

    PAGE_TITLE       = 'Katalog Zprávobot.news'
    PAGE_DESCRIPTION = 'Katalog všech zdrojů běžících na zpravobot.news. ' \
                       'Objev své oblíbené zdroje na Mastodonu.'
    SHARE_IMAGE      = 'header.jpg'   # OG/Twitter náhledový obrázek (1600×840)

    # @param records [Array<Hash>] z DataAggregator#aggregate
    # @param output_dir [String] kam zapsat soubory
    # @param updated_at [Time, Date] čas poslední aktualizace katalogu
    # @param site_url [String, nil] veřejná base URL katalogu (pro absolutní
    #   OG/canonical odkazy + sitemap). Bez ní se SEO meta degradují na relativní.
    # @param account_stubs [Boolean] generovat per-účet sdílecí HTML stuby
    #   (zdroj/<id>.html) s vlastním OG — vyžaduje site_url.
    # @return [Array<String>] absolutní cesty zapsaných souborů
    def render(records, output_dir:, updated_at: Time.now, site_url: nil, account_stubs: true)
      FileUtils.mkdir_p(output_dir)
      site = site_url.to_s.chomp('/')

      written = []
      written << write_file(output_dir, 'data.json', JSON.generate(records))
      written << write_file(output_dir, 'index.html', render_index(records, updated_at, site))
      unless site.empty?
        written << write_file(output_dir, 'sitemap.xml', render_sitemap(updated_at, site))
        written << write_file(output_dir, 'robots.txt', render_robots(site))
      end
      STATIC_ASSETS.each do |asset|
        written << write_file(output_dir, asset, File.read(template_path(asset)))
      end
      IMAGE_ASSETS.each do |asset|
        dest = File.join(output_dir, asset)
        FileUtils.cp(template_path(asset), dest)
        written << dest
      end

      written.concat(write_account_stubs(records, output_dir, site)) if account_stubs && !site.empty?

      log_info("[Renderer] Zapsáno #{written.size} souborů do #{output_dir}")
      written
    end

    private

    # Per-účet sdílecí stuby: zdroj/<id>.html s vlastním OG (avatar/bio/jméno).
    # Crawler přečte náhled, člověka stub přesměruje do katalogu s otevřeným
    # modalem (#account=<id>). Vrací zapsané cesty.
    def write_account_stubs(records, output_dir, site_url)
      stub_dir = File.join(output_dir, 'zdroj')
      FileUtils.mkdir_p(stub_dir)
      records.filter_map do |rec|
        safe_id = rec[:id].to_s.gsub(/[^a-zA-Z0-9_.\-]/, '')
        next if safe_id.empty?

        write_file(stub_dir, "#{safe_id}.html", render_account_stub(rec, site_url, safe_id))
      end
    end

    def render_index(records, updated_at, site_url = '')
      account_count    = records.size
      updated_label    = format_updated(updated_at)
      updated_iso      = to_iso(updated_at)
      main_account     = MAIN_ACCOUNT
      page_title       = PAGE_TITLE
      page_description = PAGE_DESCRIPTION
      site             = site_url.to_s.chomp('/')
      page_url         = site.empty? ? '' : "#{site}/"
      share_image      = site.empty? ? SHARE_IMAGE : "#{site}/#{SHARE_IMAGE}"
      # Explicitní UTF-8 — výchozí externí encoding může být ASCII-8BIT, což by
      # padalo při interpolaci českých řetězců (page_title/description).
      template = File.read(template_path('index.html.erb'), encoding: 'UTF-8')
      ERB.new(template, trim_mode: '-').result(binding)
    end

    # Minimální sitemap — jen domovská stránka katalogu. (Per-účet záznamy
    # přibudou ve v3 spolu s per-account OG stuby.)
    def render_sitemap(updated_at, site_url)
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url>
            <loc>#{site_url}/</loc>
            <lastmod>#{to_iso(updated_at)}</lastmod>
            <changefreq>weekly</changefreq>
            <priority>1.0</priority>
          </url>
        </urlset>
      XML
    end

    def render_robots(site_url)
      <<~TXT
        User-agent: *
        Allow: /

        Sitemap: #{site_url}/sitemap.xml
      TXT
    end

    # Statický stub jednoho zdroje — vlastní OG/Twitter meta + okamžitý redirect
    # do katalogu s otevřeným modalem. Avatar (čtvercový) → twitter card 'summary',
    # bez avataru → 'summary_large_image' s hero obrázkem.
    def render_account_stub(rec, site_url, safe_id)
      name   = rec[:display_name].to_s
      url    = "#{site_url}/zdroj/#{safe_id}.html"
      # Redirect je root-relativní → funguje na prod/test/lokálním náhledu stejně.
      # (OG/canonical zůstávají absolutní, crawler je potřebuje.)
      back   = "/#account=#{safe_id}"
      desc   = stub_description(rec)
      avatar = rec[:avatar].to_s
      image  = avatar.empty? ? "#{site_url}/#{SHARE_IMAGE}" : avatar
      card   = avatar.empty? ? 'summary_large_image' : 'summary'

      <<~HTML
        <!DOCTYPE html>
        <html lang="cs">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>#{h(name)} — #{h(PAGE_TITLE)}</title>
        <meta name="description" content="#{h(desc)}">
        <link rel="canonical" href="#{h(url)}">
        <meta property="og:type" content="profile">
        <meta property="og:site_name" content="#{h(PAGE_TITLE)}">
        <meta property="og:title" content="#{h(name)}">
        <meta property="og:description" content="#{h(desc)}">
        <meta property="og:url" content="#{h(url)}">
        <meta property="og:image" content="#{h(image)}">
        <meta property="og:locale" content="cs_CZ">
        <meta name="twitter:card" content="#{card}">
        <meta name="twitter:title" content="#{h(name)}">
        <meta name="twitter:description" content="#{h(desc)}">
        <meta name="twitter:image" content="#{h(image)}">
        <meta http-equiv="refresh" content="0; url=#{h(back)}">
        </head>
        <body style="font-family:sans-serif;padding:24px">
        <p>Přesměrování na <a href="#{h(back)}">#{h(name)}</a> v katalogu Zprávobot.news…</p>
        <script>location.replace(#{back.to_json})</script>
        </body>
        </html>
      HTML
    end

    # Plain-text popis pro meta — z bia (HTML → text, max 200 znaků), nebo fallback.
    def stub_description(rec)
      text = rec[:bio].to_s.gsub(/<[^>]+>/, ' ')
      text = CGI.unescapeHTML(text).gsub(/\s+/, ' ').strip
      return "#{rec[:display_name]} — zdroj na Zprávobot.news. Sleduj svoje oblíbené zdroje na Mastodonu." if text.empty?

      text.length > 200 ? "#{text[0, 197].rstrip}…" : text
    end

    def h(str)
      CGI.escapeHTML(str.to_s)
    end

    # ISO 8601 (YYYY-MM-DD) — strojově čitelné datum buildu pro relativní
    # "aktualizováno před X dny" počítané v app.js.
    def to_iso(time)
      d = time.respond_to?(:to_date) ? time.to_date : time
      d.strftime('%Y-%m-%d')
    end

    # 30. 5. 2026
    def format_updated(time)
      d = time.respond_to?(:to_date) ? time.to_date : time
      "#{d.day}. #{d.month}. #{d.year}"
    end

    def write_file(dir, name, content)
      path = File.join(dir, name)
      File.write(path, content)
      path
    end

    def template_path(name)
      File.join(TEMPLATE_DIR, name)
    end
  end
end
