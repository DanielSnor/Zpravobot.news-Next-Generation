# frozen_string_literal: true

require 'json'
require 'uri'
require 'cgi'
require 'time'
require_relative '../support/loggable'

module Catalog
  # Sbírá nejlepší příspěvky katalogových botů za týden přímo z Mastodonovy
  # Postgres DB (Zprávobotí DB běží ve stejném clusteru) a generuje posts.json
  # ve schématu, které čeká frontend (Posty view + lokální Search).
  #
  # Data NEjsou v katalogově DB (published_posts má jen status ID/datum bez
  # obsahu a engagementu) — engagement (reblogs/favourites) žije v Mastodonově
  # `status_stats`, text v `statuses.text`.
  #
  # Připojení: dostává hotové PG spojení (`conn`) + název Mastodon schématu
  # (`mastodon_schema`, typicky 'public'). Tabulky se kvalifikují schématem,
  # takže to funguje i přes katalogové spojení se search_path=zpravobot.
  #
  # Usage:
  #   collector = Catalog::PostsCollector.new(
  #     conn: db.conn, records: records,
  #     mastodon_schema: 'public', instance_url: 'https://zpravobot.news'
  #   )
  #   posts_json = collector.collect   # => Hash (top_by_* sekce)
  #
  class PostsCollector
    include Support::Loggable

    SECTION_MAX         = 50   # max postů na sekci (frontend bere Top 10 / Top 50)
    RISER_MIN_POSTS     = 3    # min. postů účtu pro spolehlivý průměr (skokani)
    RISER_RATIO_MIN_ENG = 5    # min. engagement pro poměrovou metriku skokanů
    WINDOW_DAYS         = 7    # okno sběru (týden)
    PUBLIC_VISIBILITY   = 0    # Mastodon enum: 0=public

    # @param conn [PG::Connection] živé PG spojení (katalogové nebo Mastodon-DB)
    # @param records [Array<Hash>] agregované katalogové záznamy (id, display_name,
    #   avatar, family, categories) — z nich bereme metadata účtu, ať nemusíme
    #   z DB skládat avatar URL
    # @param mastodon_schema [String] schéma Mastodon tabulek (default 'public')
    # @param instance_url [String] base URL instance (pro hashtag odkazy)
    # @param window_days [Integer] kolik dní zpět brát posty
    def initialize(conn:, records:, mastodon_schema: 'public',
                   instance_url: 'https://zpravobot.news', window_days: WINDOW_DAYS)
      @conn          = conn
      @records       = records
      @schema        = sanitize_schema(mastodon_schema)
      @instance_url  = instance_url.to_s.chomp('/')
      @instance_host = (URI(@instance_url).host rescue nil) || 'zpravobot.news'
      @window_days   = window_days
    end

    # @return [Hash] posts.json struktura (generated_at, total_posts, top_by_*, risers_*)
    def collect
      meta = build_account_meta
      if meta.empty?
        log_warn('[PostsCollector] Žádné eligible účty, posts.json bude prázdný')
        return build_sections([])
      end

      rows  = query_statuses(meta.keys)
      posts = rows.filter_map { |row| build_post(row, meta) }
      log_info("[PostsCollector] #{posts.size} postů od #{meta.size} účtů (okno #{@window_days} dní)")
      build_sections(posts)
    end

    private

    # username => { display_name, avatar, family, tags } z agregovaných záznamů
    def build_account_meta
      @records.each_with_object({}) do |rec, acc|
        username = rec[:id].to_s
        next if username.empty?

        acc[username] = {
          display_name: rec[:display_name].to_s,
          avatar:       rec[:avatar],
          family:       rec[:family].to_s,
          tags:         Array(rec[:categories]).map(&:to_s)
        }
      end
    end

    # Jeden dotaz do Mastodon DB: statuses + status_stats (engagement) +
    # média (has_media) + hashtagy. Jen lokální veřejné ne-boost ne-reply posty.
    def query_statuses(usernames)
      since = (Time.now.utc - (@window_days * 86_400)).iso8601
      sql = <<~SQL
        SELECT s.id::text                          AS id,
               a.username                          AS username,
               s.text                              AS text,
               s.language                          AS language,
               s.created_at                        AS created_at,
               '#{@instance_url}/@' || a.username || '/' || s.id::text AS url,
               COALESCE(ss.reblogs_count, 0)       AS reblogs_count,
               COALESCE(ss.favourites_count, 0)    AS favourites_count,
               EXISTS (
                 SELECT 1 FROM #{@schema}.media_attachments m WHERE m.status_id = s.id
               )                                   AS has_media,
               (
                 SELECT string_agg(t.name, ',')
                 FROM #{@schema}.statuses_tags st
                 JOIN #{@schema}.tags t ON t.id = st.tag_id
                 WHERE st.status_id = s.id
               )                                   AS hashtags
        FROM #{@schema}.statuses s
        JOIN #{@schema}.accounts a ON a.id = s.account_id
        LEFT JOIN #{@schema}.status_stats ss ON ss.status_id = s.id
        WHERE a.domain IS NULL
          AND lower(a.username) = ANY($1::varchar[])
          AND s.created_at >= $2
          AND s.reblog_of_id IS NULL
          AND s.in_reply_to_id IS NULL
          AND s.visibility IN (0, 1)
        ORDER BY s.created_at DESC
      SQL

      # Jména case-insensitive: v DB je `Aktualnecz`/`iDNEScz`, config klíče jsou malými.
      # visibility IN (0,1) = public + unlisted (oba jsou viditelné na profilu).
      @conn.exec_params(sql, [pg_text_array(usernames.map { |u| u.to_s.downcase }), since]).to_a
    rescue PG::Error => e
      log_warn("[PostsCollector] SQL selhal: #{e.message}")
      []
    end

    # Mastodon status řádek → posts.json záznam (schéma dle Sloníkova build_post).
    # `account_username` = config id (malými písmeny), ať sedí na catalogById/karty
    # účtů ve frontendu — Mastodon username může mít jinou velikost písmen.
    def build_post(row, meta)
      username = row['username'].to_s.downcase
      m = meta[username] || {}
      reblogs = row['reblogs_count'].to_i
      favs    = row['favourites_count'].to_i
      text    = row['text'].to_s
      hashtags = row['hashtags'].to_s.split(',').reject(&:empty?)

      {
        'id'                   => row['id'],
        'account_username'     => username,
        'account_instance'     => @instance_host,
        'account_display_name' => m[:display_name].to_s,
        'account_avatar'       => m[:avatar],
        'account_family'       => m[:family].to_s,
        'account_tags'         => m[:tags] || [],
        'hashtags'             => hashtags,
        'content_plain'        => text,
        'content_html'         => build_content_html(text),
        'has_media'            => truthy?(row['has_media']),
        'language'             => row['language'],
        'created_at'           => parse_time(row['created_at']),
        'url'                  => row['url'],
        'reblogs_count'        => reblogs,
        'favourites_count'     => favs,
        'engagement'           => reblogs + favs
      }
    end

    # Sekce jako Sloníkův consolidate_posts (frontend čte tyto klíče).
    def build_sections(posts)
      scored = score_risers(posts)
      {
        'generated_at'      => Time.now.utc.iso8601,
        'total_posts'       => posts.size,
        'top_by_engagement' => top_by(posts) { |p| p['engagement'] },
        'top_by_reblogs'    => top_by(posts) { |p| p['reblogs_count'] },
        'top_by_favourites' => top_by(posts) { |p| p['favourites_count'] },
        'top_by_date'       => posts.sort_by { |p| p['created_at'].to_s }.reverse.first(SECTION_MAX),
        'risers_absolute'   => scored.sort_by { |p| p['riser_score'] }.reverse.first(SECTION_MAX),
        'risers_ratio'      => scored.select { |p| p['engagement'] >= RISER_RATIO_MIN_ENG }
                                     .sort_by { |p| p['riser_ratio'] }.reverse.first(SECTION_MAX)
      }
    end

    def top_by(posts, &block)
      posts.sort_by(&block).reverse.first(SECTION_MAX)
    end

    # Skokani: engagement vs. průměr účtu (dosahem = rozdíl, poměrem = podíl).
    def score_risers(posts)
      posts.group_by { |p| "#{p['account_username']}@#{p['account_instance']}" }
           .flat_map do |_, acc_posts|
        next [] if acc_posts.size < RISER_MIN_POSTS

        avg = acc_posts.sum { |p| p['engagement'] }.to_f / acc_posts.size
        acc_posts.map do |p|
          e = p['engagement']
          p.merge(
            'account_avg_engagement' => avg.round(2),
            'riser_score'            => (e - avg).round(2),
            'riser_ratio'            => (avg.positive? ? (e / avg) : 0.0).round(2)
          )
        end
      end
    end

    # Plain text → bezpečné HTML s klikatelnými URL a #hashtagy.
    # Pořadí: escape → linkify URL (celé, vč. fragmentu) → #hashtag jen po
    # mezeře/začátku (takže # uvnitř URL se netrefí). Frontend dál sanitizuje.
    def build_content_html(text)
      return '' if text.to_s.strip.empty?

      html = CGI.escapeHTML(text)
      html = html.gsub(%r{https?://[^\s<]+}) do |url|
        %(<a href="#{url}" rel="nofollow noopener" target="_blank">#{url}</a>)
      end
      html = html.gsub(/(^|\s)#(\p{L}[\p{L}\p{N}_]*)/) do
        pre  = Regexp.last_match(1)
        name = Regexp.last_match(2)
        %(#{pre}<a href="#{@instance_url}/tags/#{name.downcase}" class="mention hashtag" rel="tag">#<span>#{name}</span></a>)
      end
      "<p>#{html.gsub(/\r?\n/, '<br>')}</p>"
    end

    def truthy?(val)
      val == true || val == 't' || val == 'true'
    end

    def parse_time(val)
      return val.utc.iso8601 if val.is_a?(Time)

      Time.parse(val.to_s).utc.iso8601
    rescue ArgumentError, TypeError
      val.to_s
    end

    # PG text[] literál z pole stringů (account_id = alfanumerika+_, ale i tak
    # bezpečně uvozujeme).
    def pg_text_array(values)
      inner = values.map { |v| %("#{v.to_s.gsub('\\', '\\\\\\\\').gsub('"', '\\"')}") }.join(',')
      "{#{inner}}"
    end

    def sanitize_schema(name)
      s = name.to_s
      raise ArgumentError, "Nevalidní Mastodon schéma: #{s.inspect}" unless s.match?(/\A[a-z_][a-z0-9_]*\z/)

      s
    end
  end
end
