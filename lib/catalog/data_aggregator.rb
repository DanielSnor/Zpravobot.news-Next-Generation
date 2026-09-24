# frozen_string_literal: true

require 'set'
require 'date'
require_relative '../support/loggable'
require_relative '../stats/mastodon_stats'
require_relative '../stats/snapshot_store'

module Catalog
  # Spojuje tři zdroje pravdy do jednoho pole záznamů pro katalog:
  #
  #   1. config/mastodon_accounts.yml  → type, family, categories, instance, aggregator
  #   2. config/sources/*.yml          → language (default 'cs'), source_details (platforma+handle+URL)
  #   3. Mastodon API + DB snapshot    → avatar, display_name, bio, followers, posts/week,
  #                                      created_at (z verify_credentials, fallback nejstarší snapshot)
  #
  # Vynechává z generace účty, které do veřejného katalogu nepatří:
  #   - instance jiná než zpravobot.news (zdroje na cizích Mastodon instancích)
  #   - bez family                       (nerekategorizované/sběrné boty, např. betabot)
  # Agregátory (aggregator: true) jsou plnohodnotné zdroje a v katalogu zůstávají.
  #
  # Usage:
  #   agg = Catalog::DataAggregator.new(
  #     config_loader: loader,
  #     db: db,
  #     mastodon_instance: 'https://zpravobot.news'
  #   )
  #   records = agg.aggregate   # => Array<Hash>, jeden záznam na účet
  #
  class DataAggregator
    include Support::Loggable

    DEFAULT_LANGUAGE = 'cs'
    LOCAL_INSTANCE_MARKER = 'zpravobot.news'

    # Šablony pro odkaz na originální profil podle platformy. `%s` = handle.
    # `rss` nemá šablonu — používá feed_url ze source YAML. `youtube` má dvojí
    # tvar: @handle (preferováno), nebo /channel/<id> když handle chybí.
    URL_TEMPLATES = {
      'twitter'   => 'https://x.com/%s',
      'bluesky'   => 'https://bsky.app/profile/%s',
      'threads'   => 'https://www.threads.net/@%s',
      'facebook'  => 'https://www.facebook.com/%s',
      'instagram' => 'https://www.instagram.com/%s',
      'youtube'   => 'https://www.youtube.com/@%s',
      'rss'       => nil
    }.freeze

    # @param config_loader [Config::ConfigLoader]
    # @param db [State::DatabaseConnection]
    # @param mastodon_instance [String] base URL hlavní instance
    # @param mastodon_fetcher [Stats::MastodonStats, nil] injectable pro testy
    # @param snapshot_store [Stats::SnapshotStore, nil] injectable pro testy
    def initialize(config_loader:, db:, mastodon_instance: 'https://zpravobot.news',
                   mastodon_fetcher: nil, snapshot_store: nil)
      @config_loader     = config_loader
      @db                = db
      @mastodon_instance = mastodon_instance.to_s.chomp('/')
      @mastodon_fetcher  = mastodon_fetcher
      @snapshot_store    = snapshot_store
    end

    # @return [Array<Hash>] záznamy seřazené podle followers desc, pak display_name
    def aggregate
      accounts = @config_loader.load_all_mastodon_accounts
      eligible = accounts.select { |account_id, creds| include_account?(account_id, creds) }
      log_info("[DataAggregator] #{eligible.size}/#{accounts.size} účtů projde do katalogu")

      languages_by_account = build_languages_map
      details_by_account   = build_source_details_map

      mastodon_data = fetch_mastodon_data(eligible)
      snapshot_data = fetch_snapshot_data
      previous_data = fetch_previous_snapshot_data(snapshot_data)
      created_dates = fetch_created_at_dates

      records = eligible.map do |account_id, creds|
        details = details_by_account[account_id.to_s] || []
        build_record(
          account_id.to_s, creds,
          mastodon: mastodon_data[account_id.to_s] || {},
          snapshot: snapshot_data[account_id.to_s] || {},
          previous: previous_data[account_id.to_s] || {},
          language: languages_by_account[account_id.to_s] || DEFAULT_LANGUAGE,
          source_details: details,
          snapshot_created_at: created_dates[account_id.to_s]
        )
      end

      records.sort_by { |r| [-r[:followers], r[:display_name].to_s.downcase] }
    end

    private

    # Účet patří do katalogu pouze pokud:
    #   - běží na zpravobot.news (prázdná instance = lokální default; účty na
    #     cizích Mastodon instancích do katalogu nepatří)
    #   - má vyplněnou family (prošel rekategorizací)
    #
    # Agregátory (aggregator: true) se NEVYNECHÁVAJÍ — v našem pojetí je agregátor
    # stále jeden samostatný zdroj, jen obohacený z více vstupů (např. DVTVcz = X
    # + YT videa DVTV). Sběrné/testovací boty bez family (např. betabot) odfiltruje
    # až kontrola family.
    def include_account?(_account_id, creds)
      instance = creds[:instance].to_s
      return false unless instance.empty? || instance.include?(LOCAL_INSTANCE_MARKER)

      family = creds[:family].to_s
      return false if family.empty?

      true
    end

    # account_id => language. Jeden source → jeho jazyk. Víc sourců se stejným
    # jazykem → ten jazyk. Víc různých jazyků → DEFAULT_LANGUAGE.
    def build_languages_map
      langs = Hash.new { |h, k| h[k] = Set.new }
      @config_loader.load_all_sources.each do |source|
        account = source.dig(:target, :mastodon_account)&.to_s
        next unless account

        lang = source[:language].to_s.downcase
        lang = DEFAULT_LANGUAGE if lang.empty?
        langs[account].add(lang)
      end

      langs.transform_values do |set|
        set.size == 1 ? set.first : DEFAULT_LANGUAGE
      end
    end

    # account_id => [{ platform:, handle:, url: }, ...], deduplikované a seřazené
    # podle platformy. Z toho se na klientovi i v build_record odvozuje plochý
    # seznam source_platforms.
    #
    # "Efektivní platforma" zohledňuje RSS feedy ze sociálních sítí (platform: rss
    # + rss_source_type: instagram → 'instagram'), aby řezy a odkazy ukazovaly
    # skutečný původ, ne generické 'rss'.
    def build_source_details_map
      details = Hash.new { |h, k| h[k] = [] }
      seen    = Hash.new { |h, k| h[k] = Set.new }

      @config_loader.load_all_sources.each do |source|
        account  = source.dig(:target, :mastodon_account)&.to_s
        platform = effective_platform(source)
        next if account.nil? || platform.empty?

        handle = extract_handle(source)
        url    = build_source_url(platform, handle, source)
        key    = [platform, handle, url]
        next if seen[account].include?(key)

        seen[account].add(key)
        details[account] << { platform: platform, handle: handle, url: url }
      end

      details.transform_values { |arr| arr.sort_by { |d| d[:platform] } }
    end

    # Skutečná zdrojová platforma: rss_source_type má přednost před platform,
    # aby se FB/IG/Threads feedy přicházející přes RSS.app nehlásily jako 'rss'.
    def effective_platform(source)
      type = source[:rss_source_type].to_s
      return type unless type.empty?

      source[:platform].to_s
    end

    # Handle originálního profilu — hledá se na třech obvyklých místech:
    #   source.handle (twitter/bluesky/fb/yt), target.social_profile.handle (IG přes RSS),
    #   profile_sync.social_profile.handle (RSS feed s ručně doplněným social profilem).
    # @return [String, nil]
    def extract_handle(source)
      handle = source.dig(:source, :handle) ||
               source.dig(:target, :social_profile, :handle) ||
               source.dig(:profile_sync, :social_profile, :handle)
      handle = handle.to_s
      handle.empty? ? nil : handle
    end

    # URL na originální profil. RSS bez social handle → feed_url. YouTube bez
    # handle → /channel/<channel_id>. Ostatní → šablona % handle (nil bez handle).
    # @return [String, nil]
    def build_source_url(platform, handle, source)
      if platform == 'youtube' && (handle.nil? || handle.empty?)
        channel = source.dig(:source, :channel_id).to_s
        return channel.empty? ? nil : "https://www.youtube.com/channel/#{channel}"
      end

      template = URL_TEMPLATES[platform]
      if template.nil?
        # rss (a neznámé platformy) — odkaz vede přímo na feed
        feed = source.dig(:source, :feed_url).to_s
        return feed.empty? ? nil : feed
      end

      return nil if handle.nil? || handle.empty?

      format(template, handle)
    end

    # Profilová data (avatar, display_name, followers) z Mastodon API.
    # Při selhání pro jednotlivý účet zůstane prázdný hash → fallbacky v build_record.
    def fetch_mastodon_data(eligible)
      fetcher = @mastodon_fetcher ||
                Stats::MastodonStats.new(eligible, @mastodon_instance)
      fetcher.fetch_all(delay: 0.3)
    rescue StandardError => e
      log_warn("[DataAggregator] Mastodon fetch selhal: #{e.message}")
      {}
    end

    # Nejnovější snapshot per account (followers, posts_week) z DB.
    def fetch_snapshot_data
      store = @snapshot_store || Stats::SnapshotStore.new(@db)
      store.latest_snapshot
    rescue StandardError => e
      log_warn("[DataAggregator] Snapshot načtení selhalo: #{e.message}")
      {}
    end

    # Snapshot ~1 týden před NEJNOVĚJŠÍM snapshotem (followers, posts_week) pro
    # výpočet "skokanů týdne". Kotvou je datum nejnovějšího snapshotu, ne datum
    # buildu: snapshoty vznikají týdně (neděle 20:00), build jede denně a okno
    # ±3 dny kolem "dnes − 7" by od čtvrtka do neděle chytilo nejnovější snapshot
    # a všechny delty by byly nulové. Když historie chybí, vrací {} → delty nil.
    def fetch_previous_snapshot_data(latest)
      store = @snapshot_store || Stats::SnapshotStore.new(@db)
      anchor = latest_snapshot_date(latest) || Date.today
      store.previous_snapshot(anchor, weeks_back: 1) || {}
    rescue StandardError => e
      log_warn("[DataAggregator] Předchozí snapshot selhal: #{e.message}")
      {}
    end

    # Datum nejnovějšího snapshotu napříč účty; nil bez dat nebo bez snapshot_date.
    def latest_snapshot_date(latest)
      newest = latest.values.filter_map { |s| s[:snapshot_date] }.max
      newest && Date.parse(newest.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # account_id => 'YYYY-MM-DD' nejstaršího snapshotu (proxy za "přidán dne").
    # Účty bez snapshotu v mapě chybí → created_at zůstane nil.
    def fetch_created_at_dates
      store = @snapshot_store || Stats::SnapshotStore.new(@db)
      store.oldest_snapshot_dates
    rescue StandardError => e
      log_warn("[DataAggregator] Načtení created_at selhalo: #{e.message}")
      {}
    end

    # "2024-03-15T00:00:00.000Z" → "2024-03-15"; prázdné/nevalidní → nil.
    def normalize_date(value)
      str = value.to_s
      return nil if str.empty?

      str[0, 10] if str =~ /\A\d{4}-\d{2}-\d{2}/
    end

    def build_record(account_id, creds, mastodon:, snapshot:, previous:, language:, source_details:, snapshot_created_at:)
      display_name = mastodon[:display_name].to_s
      display_name = account_id if display_name.empty?

      avatar = mastodon[:avatar].to_s
      avatar = nil if avatar.empty?

      bio = mastodon[:note].to_s
      bio = nil if bio.empty?

      # created_at primárně z Mastodon API (verify_credentials → datum vzniku účtu
      # na instanci = kdy byl bot přidán). Fallback na nejstarší snapshot, jinak nil.
      created_at = normalize_date(mastodon[:created_at]) || snapshot_created_at

      followers  = snapshot[:followers].to_i
      posts_week = snapshot[:posts_week].to_i

      # Týdenní delty pro žebříčky "skokan týdne". nil = nemáme předchozí snapshot,
      # účet tedy do skokanů nepatří (na klientovi se filtruje delta != null && > 0).
      followers_delta = previous[:followers] ? followers  - previous[:followers].to_i : nil
      activity_delta  = previous[:posts_week] ? posts_week - previous[:posts_week].to_i : nil

      # Plochý, dedup. seznam platforem pro štítky/řezy odvozený ze source_details.
      platforms = source_details.map { |d| d[:platform] }.uniq.sort

      {
        id:               account_id,
        display_name:     display_name,
        type:             creds[:type].to_s,
        family:           creds[:family].to_s,
        language:         language,
        categories:       Array(creds[:categories]).map(&:to_s),
        avatar:           avatar,
        bio:              bio,
        followers:        followers,
        posts_week:       posts_week,
        followers_delta:  followers_delta,
        activity_delta:   activity_delta,
        created_at:       created_at,
        profile_url:      "#{@mastodon_instance}/@#{account_id}",
        source_platforms: platforms,
        source_details:   source_details
      }
    end
  end
end
