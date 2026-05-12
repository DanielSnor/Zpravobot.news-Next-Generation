# frozen_string_literal: true

class SourceGenerator
  def collect_data
    data = {}

    # 1. Platforma
    data[:platform] = PLATFORM_MAP[ask_choice('Platforma', PLATFORM_OPTIONS)]
    if %w[facebook instagram threads].include?(data[:platform])
      data[:rss_source_type] = data[:platform]
      data[:platform] = 'rss'
    end
    puts

    # 2. Pro Bluesky: typ zdroje (handle vs feed) - PRED collect_source_data
    if data[:platform] == 'bluesky'
      collect_bluesky_source_type(data)
      puts
    end

    # 3. Source-specific udaje (handle, feed_url, channel_id, etc.)
    collect_source_data(data)
    puts

    # 4. Pro RSS: typ zdroje (RSS, jiny) - FB/IG uz nastaveno z volby platformy
    if data[:platform] == 'rss'
      if data[:rss_source_type].nil?
        collect_rss_source_type(data)
      elsif data[:rss_source_type] == 'facebook'
        collect_facebook_handle_for_rss(data)
      end
      puts
    end

    # 5. Mastodon ucet
    collect_mastodon_account(data)
    puts

    # 6. Source name (jen pro Twitter/Bluesky profily - pouziva se v hlavicce repostu a quote)
    if data[:platform] == 'twitter' || (data[:platform] == 'bluesky' && data[:bluesky_source_type] != 'feed')
      data[:source_name] = get_source_display_name(data)
      puts
    end

    # 7. Generujeme a validujeme ID
    collect_source_id(data)
    puts

    # 8. Rozsirene nastaveni (pokud neni quick mode)
    unless @quick_mode
      if ask_yes_no('Nastavit rozšířené možnosti?', default: false)
        puts
        collect_extended_data(data)
      end
    end

    # 9. Jazyk zdroje (použije se v profile_sync i případně dalších místech)
    data[:language] = ask_choice('Jazyk zdroje', LANGUAGES, default: 'cs')
    puts

    # 10. Inicializacni cas pro databazi
    data[:init_time] = collect_init_time
    puts

    # Vychozi hodnoty pro profile_sync
    if data[:profile_sync_enabled].nil?
      if data[:platform] == 'twitter'
        data[:profile_sync_enabled] = !data[:is_aggregator]
      elsif data[:platform] == 'bluesky' && data[:bluesky_source_type] != 'feed'
        data[:profile_sync_enabled] = !data[:is_aggregator]
      elsif data[:platform] == 'rss' && data[:rss_source_type] == 'instagram'
        data[:profile_sync_enabled] = !data[:is_aggregator]
      elsif data[:platform] == 'rss' && data[:rss_source_type] == 'threads'
        data[:profile_sync_enabled] = !data[:is_aggregator]
      elsif data[:platform] == 'rss' && data[:rss_source_type] == 'facebook' && data[:handle]
        data[:profile_sync_enabled] = !data[:is_aggregator]
      else
        data[:profile_sync_enabled] = false
      end
    end

    # Vychozi content mode pro RSS/YouTube
    if %w[rss youtube].include?(data[:platform]) && data[:content_mode].nil?
      data[:content_mode] = 'text'
    end

    # Vychozi hodnoty pro nitter_processing (Twitter only)
    if data[:platform] == 'twitter' && data[:nitter_processing_enabled].nil?
      data[:nitter_processing_enabled] = false  # default: zakazano
    end

    # Vychozi hodnoty pro thread_handling
    if %w[twitter bluesky].include?(data[:platform]) && data[:thread_handling_enabled].nil?
      if data[:platform] == 'twitter' && data[:nitter_processing_enabled] == false
        data[:thread_handling_enabled] = false
      else
        data[:thread_handling_enabled] = true  # default: povoleno
      end
    end

    data
  end

  def collect_source_data(data)
    case data[:platform]
    when 'twitter'
      handle = ask('Twitter handle (bez @)', required: true)
      data[:handle] = sanitize_handle(handle)
    when 'bluesky'
      if data[:bluesky_source_type] == 'feed'
        collect_bluesky_feed(data)
      else
        collect_bluesky_handle(data)
      end
    when 'rss'
      data[:feed_url] = ask('RSS feed URL', required: true)
    when 'youtube'
      puts '  YouTube Channel ID (začíná UC...)'
      puts '  ℹ️  Jak získat: YouTube kanál → About → Share channel → Copy channel ID'
      puts '  ℹ️  Nebo: https://commentpicker.com/youtube-channel-id.php'
      puts
      channel_id = ask('Channel ID', required: true).strip

      unless channel_id.start_with?('UC')
        puts '  ⚠️  Channel ID musí začínat "UC" (např. UCCsrIy9t3CFXHEU9MLp0SBw)'
        puts '  ⚠️  Handle (@jméno) není podporováno - YouTube blokuje jeho překlad na ID.'
        exit 1
      end

      data[:channel_id] = channel_id

      puts
      puts '  Playlist ID (volitelné — pro sledování konkrétního playlistu místo celého kanálu)'
      puts '  ℹ️  Začíná PL..., najdete v URL playlistu jako ?list=PLxxxxx'
      puts '  ℹ️  Nechte prázdné pro sledování celého kanálu.'
      playlist_id = ask('Playlist ID (volitelné)', required: false)&.strip
      if playlist_id && !playlist_id.empty?
        unless playlist_id.start_with?('PL')
          puts '  ⚠️  Playlist ID musí začínat "PL" (např. PLJlTDcBkLoOFuC7Fe6NTfvoV-4boZCyBL)'
          puts '  ⚠️  Pokračuji bez playlist filtru — bude se sledovat celý kanál.'
          playlist_id = nil
        end
        data[:playlist_id] = playlist_id if playlist_id
      end
    end
  end

  def collect_bluesky_source_type(data)
    choice = ask_choice('Typ Bluesky zdroje', BLUESKY_SOURCE_TYPE_OPTIONS, default: 'Profil (handle)')
    data[:bluesky_source_type] = BLUESKY_SOURCE_TYPE_MAP[choice]
  end

  def collect_bluesky_handle(data)
    handle = ask('Bluesky handle (např. user.bsky.social)', required: true)
    handle = sanitize_handle(handle)
    # Pridej .bsky.social pokud handle neobsahuje tecku
    handle = "#{handle}.bsky.social" unless handle.include?('.')
    data[:handle] = handle
  end

  def collect_bluesky_feed(data)
    puts '  Zadej URL feedu (např. https://bsky.app/profile/user/feed/feedid)'
    feed_url = ask('Feed URL', required: true)

    # Validace formatu
    unless feed_url =~ %r{bsky\.app/profile/([^/]+)/feed/([^/?]+)}
      puts '  ⚠️  Neplatný formát URL. Očekávaný: https://bsky.app/profile/{handle}/feed/{rkey}'
      return collect_bluesky_feed(data)
    end

    data[:feed_url] = feed_url

    # Extrahuj handle a rkey pro informaci
    feed_url =~ %r{bsky\.app/profile/([^/]+)/feed/([^/?]+)}
    feed_creator = $1
    feed_rkey = $2

    puts "  ℹ️  Feed creator: #{feed_creator}"
    puts "  ℹ️  Feed rkey: #{feed_rkey}"

    # Zkus ziskat nazev feedu
    feed_name = fetch_bluesky_feed_name(feed_url)
    if feed_name
      data[:feed_name] = feed_name
      puts "  📋 Název feedu: #{feed_name}"
    end
  end

  def collect_rss_source_type(data)
    choice = ask_choice('Typ RSS zdroje', RSS_SOURCE_TYPE_OPTIONS, default: 'RSS')
    data[:rss_source_type] = RSS_SOURCE_TYPE_MAP[choice]

    case data[:rss_source_type]
    when 'facebook'
      collect_facebook_handle_for_rss(data)
    when 'other'
      custom_label = ask('Vlastní název typu (např. TikTok, Threads)', required: true)
      data[:rss_custom_label] = custom_label.strip
      data[:rss_custom_suffix] = sanitize_id(custom_label)
    end
  end

  # Collect Facebook page handle for RSS/Facebook sources (for profile sync)
  def collect_facebook_handle_for_rss(data)
    puts
    puts '  Facebook page handle (pro synchronizaci profilu)'
    puts '  ℹ️  Příklad: headliner.cz, ct24zive (z URL facebook.com/HANDLE)'
    puts
    handle = ask('Page handle', required: false)
    if handle && !handle.empty?
      handle = handle.gsub(%r{^https?://[^/]+/}, '').gsub(/^@/, '')
      data[:handle] = handle
    end
  end

  def collect_mastodon_account(data)
    aggregators = load_aggregator_accounts

    options = ['Nový účet'] + aggregators.map { |acc| "#{acc[:id]} (agregátor)" }
    puts '  Mastodon účet:'
    options.each_with_index do |opt, idx|
      marker = idx == 0 ? ' (default)' : ''
      puts "    #{idx + 1}. #{opt}#{marker}"
    end

    print '  Vyber číslo [1]: '
    answer = safe_gets
    answer = answer.empty? ? 1 : answer.to_i

    if answer == 1
      collect_new_mastodon_account(data)
    elsif answer > 1 && answer <= aggregators.length + 1
      selected = aggregators[answer - 2]
      data[:mastodon_account] = selected[:id]
      data[:is_aggregator] = true
      puts "  ℹ️  Přidáváš zdroj k agregátoru '#{selected[:id]}'"

      aggregator_instance = selected[:config]['instance'] || DEFAULT_INSTANCE
      unless aggregator_instance.include?('zpravobot.news')
        data[:mastodon_instance] = aggregator_instance
        collect_truncation_settings(data)
      end
    else
      puts '  ⚠️  Neplatná volba, zkus znovu.'
      collect_mastodon_account(data)
    end
  end

  def collect_new_mastodon_account(data)
    puts

    # ID uctu - predvyplnit z handle (Twitter/Bluesky/Facebook)
    default_account_id = case data[:platform]
                         when 'twitter'
                           sanitize_id(data[:handle]) if data[:handle]
                         when 'bluesky'
                           sanitize_id(data[:handle]) if data[:handle] && data[:bluesky_source_type] != 'feed'
                         when 'rss'
                           sanitize_id(data[:handle]) if data[:handle] && data[:rss_source_type] == 'facebook'
                         end

    loop do
      account_id = ask('Mastodon account ID (např. denikn, idnes)', required: true, default: default_account_id)
      account_id = sanitize_id(account_id)

      if mastodon_account_exists?(account_id)
        puts "  ⚠️  Účet '#{account_id}' již existuje v mastodon_accounts.yml!"
        puts '  Zadej jiné ID, nebo vyber existující účet.'
      else
        data[:mastodon_account] = account_id
        break
      end
    end

    # Token
    data[:mastodon_token] = ask('Mastodon access token', required: true)

    # Instance
    if @quick_mode
      data[:mastodon_instance] = DEFAULT_INSTANCE
    else
      instance = ask("Mastodon instance URL", default: DEFAULT_INSTANCE, required: false)
      data[:mastodon_instance] = instance.empty? ? DEFAULT_INSTANCE : instance
    end

    # Truncation settings pro non-zpravobot instance
    unless data[:mastodon_instance].include?('zpravobot.news')
      collect_truncation_settings(data)
    end

    # Agregator?
    data[:is_aggregator] = ask_yes_no('Je to agregátor (více zdrojů → jeden bot)?', default: false)

    # Kategorie
    categories_input = ask('Kategorie (oddělené čárkou, např. news, politics)', required: false)
    data[:categories] = parse_categories(categories_input)

    # Ulozime pro pozdejsi zapis
    @new_mastodon_account = {
      id: data[:mastodon_account],
      token: data[:mastodon_token],
      instance: data[:mastodon_instance],
      aggregator: data[:is_aggregator],
      categories: data[:categories]
    }
  end

  # Truncation settings pro non-zpravobot instance
  def collect_truncation_settings(data)
    puts
    puts "  📝 Instance '#{extract_instance_domain(data[:mastodon_instance])}' není zpravobot.news"
    puts "     Nastavím parametry."
    puts

    # Limit poctu znaku
    max_length_input = ask('Limit počtu znaků instance', default: '500', required: false)
    data[:instance_max_length] = max_length_input.to_i
    data[:instance_max_length] = 500 if data[:instance_max_length] <= 0

    # Soft threshold
    default_threshold = (data[:instance_max_length] * 0.95).to_i
    threshold_input = ask("Soft threshold pro zkracování", default: default_threshold.to_s, required: false)
    data[:instance_soft_threshold] = threshold_input.to_i
    data[:instance_soft_threshold] = default_threshold if data[:instance_soft_threshold] <= 0

    # Twitter URL domain
    if data[:platform] == 'twitter'
      collect_twitter_url_domain(data)
    end

    puts
    puts "  ✅ Nastavení pro non-zpravobot instanci:"
    puts "     • Max length: #{data[:instance_max_length]}"
    puts "     • Soft threshold: #{data[:instance_soft_threshold]}"
    puts "     • URL domain: #{data[:twitter_url_domain]}" if data[:twitter_url_domain]
  end

  # Collect Twitter URL domain for non-zpravobot instances
  def collect_twitter_url_domain(data)
    puts
    choice = ask_choice('Doména pro odkazy v příspěvcích', TWITTER_URL_DOMAIN_OPTIONS)
    domain = TWITTER_URL_DOMAINS[TWITTER_URL_DOMAIN_OPTIONS.index(choice)]
    data[:twitter_url_domain] = domain
    data[:full_text_domain] = domain
  end

  def collect_source_id(data)
    default_id = generate_id(data)

    loop do
      puts "  📋 Navrhované ID: #{default_id}"
      custom_id = ask('Vlastní ID (Enter = ponechat)', required: false)
      source_id = custom_id.empty? ? default_id : sanitize_id(custom_id)

      if source_exists?(source_id)
        puts "  ⚠️  Soubor sources/#{source_id}.yml již existuje!"
        puts '  Zadej jiné ID.'
        default_id = "#{source_id}_2"
      else
        data[:id] = source_id
        break
      end
    end
  end

  # Collect initialization time for source_state
  def collect_init_time
    ask_init_time
  end

  def collect_extended_data(data)
    # Scheduling
    separator('Scheduling')
    data[:priority] = ask_choice('Priorita', PRIORITIES, default: 'normal')
    puts "  ℹ️  Interval se řídí prioritou: high=5min, normal=20min, low=55min"
    data[:max_posts_per_run] = ask_number('Max postů na run', default: 10)
    puts

    # Filtering
    separator('Filtering')
    if %w[twitter bluesky].include?(data[:platform])
      data[:skip_replies] = true
      data[:skip_retweets] = false
    end

    banned = ask('Zakázané fráze (oddělené čárkou)', required: false)
    data[:banned_phrases] = banned.split(',').map { |p| p.strip.gsub(/["']/, '') }.reject(&:empty?) unless banned.empty?
    puts

    # Nitter Processing (jen pro Twitter)
    if data[:platform] == 'twitter'
      separator('Nitter Processing')
      puts '  Nitter processing umožňuje získat plný text a všechny obrázky.'
      puts '  Pro sportovní boty a high-volume zdroje lze zakázat.'
      puts
      data[:nitter_processing_enabled] = ask_yes_no('Povolit Nitter processing (Tier 2)?', default: false)
      puts
    end

    # Thread Handling (pro Twitter/Bluesky)
    if %w[twitter bluesky].include?(data[:platform])
      separator('Thread Handling')
      if data[:platform] == 'twitter' && data[:nitter_processing_enabled] == false
        puts '  ⚠️  Nitter processing je vypnutý → vlákna automaticky vypnuta'
        data[:thread_handling_enabled] = false
      else
        data[:thread_handling_enabled] = ask_yes_no('Povolit zpracování vláken?', default: true)
      end
      puts
    end

    # Content (RSS/YouTube)
    if %w[rss youtube].include?(data[:platform])
      separator('Content')
      data[:content_mode] = ask_content_mode

      if data[:platform] == 'youtube'
        data[:include_thumbnail] = ask_yes_no('Zahrnout thumbnail?', default: true)
        data[:no_shorts] = ask_yes_no('Vyloučit Shorts (UULF playlist)?', default: false)
        data[:include_views] = ask_yes_no('Zobrazit počet zhlédnutí?', default: false)
      end
      puts
    end

    # YouTube mentions (optional)
    if data[:platform] == 'youtube'
      separator('Mentions')
      data[:youtube_mentions_enabled] = ask_yes_no('Transformovat @zmínky na YouTube odkazy?', default: true)
      if data[:youtube_mentions_enabled]
        puts '  ℹ️  @channel → @channel (https://youtube.com/@channel)'
      end
      puts
    end

    # Profile sync
    plain_rss = data[:platform] == 'rss' &&
                !%w[facebook instagram].include?(data[:rss_source_type].to_s)

    show_profile_sync = data[:platform] == 'twitter' ||
                        (data[:platform] == 'bluesky' && data[:bluesky_source_type] != 'feed') ||
                        (data[:platform] == 'rss' && data[:rss_source_type] == 'instagram') ||
                        (data[:platform] == 'rss' && data[:rss_source_type] == 'threads') ||
                        (data[:platform] == 'rss' && data[:rss_source_type] == 'facebook' && data[:handle]) ||
                        data[:platform] == 'youtube'

    if plain_rss
      separator('Profile Sync (RSS)')
      puts '  Pokud má zdroj sociální profil, zadejte platformu a handle.'
      puts '  Synchronizuje avatar, bio a pole z dané platformy.'
      puts
      platform_options = ['Twitter/X', 'Facebook', 'Instagram', 'Threads', 'YouTube', 'Bluesky', '(přeskočit)']
      platform_choice = ask_choice('Sociální platforma', platform_options, default: '(přeskočit)')

      unless platform_choice == '(přeskočit)'
        platform_map = {
          'Twitter/X' => 'twitter', 'Facebook' => 'facebook',
          'Instagram' => 'instagram', 'Threads' => 'threads',
          'YouTube' => 'youtube', 'Bluesky' => 'bluesky'
        }
        data[:social_profile_platform] = platform_map[platform_choice]
        handle = ask('Handle (bez @, bez https://)', required: true)
        handle = handle.gsub(%r{^https?://[^/]+/}, '').gsub(/^@/, '').chomp('/')
        data[:social_profile_handle] = handle
        default_sync = !data[:is_aggregator]
        data[:profile_sync_enabled] = ask_yes_no('Povolit sync profilu?', default: default_sync)
        if data[:profile_sync_enabled]
          default_retention = '30'
          data[:retention_days] = ask_choice('Retence (dní)', RETENTION_OPTIONS.map(&:to_s), default: default_retention).to_i
        end
      end
      puts
    elsif show_profile_sync
      separator('Profile Sync')
      default_sync = !data[:is_aggregator]
      data[:profile_sync_enabled] = ask_yes_no('Povolit sync profilu?', default: default_sync)

      if data[:profile_sync_enabled]
        if data[:platform] == 'rss' && data[:rss_source_type] == 'instagram'
          puts '  Instagram handle (bez @, např. tom.holic)'
          handle = ask('Instagram handle', required: false).strip
          handle = handle.gsub(/^@/, '')
          if handle.empty?
            puts '  ⚠️  Handle nevyplněn — sync profilu bude zakázán'
            data[:profile_sync_enabled] = false
          else
            data[:social_profile_platform] = 'instagram'
            data[:social_profile_handle] = handle
          end
        end

        if data[:platform] == 'rss' && data[:rss_source_type] == 'threads'
          puts '  Threads handle (bez @, např. jirikostaf1)'
          handle = ask('Threads handle', required: false).strip
          handle = handle.gsub(/^@/, '')
          if handle.empty?
            puts '  ⚠️  Handle nevyplněn — sync profilu bude zakázán'
            data[:profile_sync_enabled] = false
          else
            data[:social_profile_platform] = 'threads'
            data[:social_profile_handle] = handle
          end
        end

        if data[:platform] == 'youtube'
          puts '  YouTube handle (bez @, např. MistrdaBingu)'
          puts '  ℹ️  Bez handle nebude sync profilu fungovat'
          handle = ask('YouTube handle', required: false).strip
          handle = handle.gsub(/^@/, '')
          data[:handle] = handle.empty? ? nil : handle
          if data[:handle].nil?
            puts '  ⚠️  Handle nevyplněn — sync profilu bude zakázán'
            data[:profile_sync_enabled] = false
          end
        end

        if data[:profile_sync_enabled]
          default_retention = '30'
          data[:retention_days] = ask_choice('Retence (dní)', RETENTION_OPTIONS.map(&:to_s), default: default_retention).to_i
        end
      end
      puts
    end

    # Processing - URL domain fixes
    separator('Processing')
    data[:url_domain_fixes] = collect_url_domain_fixes
    puts

    # Target visibility
    separator('Target')
    data[:visibility] = ask_choice('Viditelnost postů', VISIBILITIES, default: 'public')
    puts
  end

  # Ask for content mode (RSS/YouTube)
  def ask_content_mode
    choice = ask_choice('Způsob sestavení obsahu', CONTENT_MODE_OPTIONS, default: CONTENT_MODE_OPTIONS.first)
    CONTENT_MODE_MAP[choice]
  end

  # Collect URL domain fixes
  def collect_url_domain_fixes
    puts '  URL Domain Fixes - přidání https:// k holým doménám'
    puts '  (např. "idnes.cz/clanek" → "https://denikn.cz/clanek")'
    puts '  Časté u Bluesky postů s odkazy bez protokolu.'
    puts

    domains = ask('Domény (oddělené čárkou, např. denikn.cz, rspkt.cz)', required: false)
    return [] if domains.empty?

    # Sanitize: remove quotes, https://, http://, www., trailing slashes
    domains.split(',').map do |domain|
      d = domain.strip.downcase
      d = d.gsub(/["']/, '')        # Remove quotes (for copy/paste from YAML)
      d = d.sub(%r{^https?://}, '')
      d = d.sub(/^www\./, '')
      d = d.sub(%r{/$}, '')
      d
    end.reject(&:empty?).uniq
  end
end
