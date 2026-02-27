# frozen_string_literal: true

class SourceGenerator
  def generate_yaml(data)
    lines = []

    # Header
    lines << '# ============================================================'
    lines << "# Bot: #{data[:id]}"
    lines << '# ============================================================'
    lines << "# Mastodon: @#{data[:mastodon_account]}@zpravobot.news"
    lines << '# ============================================================'
    lines << ''

    # Identity
    lines << "id: #{data[:id]}"
    lines << 'enabled: true'
    lines << "platform: #{data[:platform]}"
    if data[:platform] == 'bluesky' && data[:bluesky_source_type] == 'feed'
      lines << "bluesky_source_type: feed"
    end
    lines << ''

    # Source
    lines << '# Zdroj dat'
    lines << 'source:'
    case data[:platform]
    when 'twitter'
      lines << "  handle: #{yaml_quote(data[:handle])}"
    when 'bluesky'
      if data[:bluesky_source_type] == 'feed'
        lines << "  feed_url: #{yaml_quote(data[:feed_url])}"
        lines << "  feed_name: #{yaml_quote(data[:feed_name])}" if data[:feed_name]
      else
        lines << "  handle: #{yaml_quote(data[:handle])}"
      end
    when 'rss'
      lines << "  feed_url: #{yaml_quote(data[:feed_url])}"
      lines << "  handle: #{yaml_quote(data[:handle])}  # Facebook page handle pro profile sync" if data[:handle] && data[:rss_source_type] == 'facebook'
    when 'youtube'
      lines << "  channel_id: #{yaml_quote(data[:channel_id])}"
    end
    lines << ''

    # Target
    lines << '# Cíl publikace'
    lines << 'target:'
    lines << "  mastodon_account: #{data[:mastodon_account]}"
    lines << "  visibility: #{data[:visibility]}" if data[:visibility] && data[:visibility] != 'public'
    lines << ''

    # Truncation settings (pro non-zpravobot instance)
    if data[:instance_max_length]
      lines << '# Zkracování (pro instance s limitem znaků)'
      lines << 'truncation:'
      lines << "  max_length: #{data[:instance_max_length]}"
      lines << "  soft_threshold: #{data[:instance_soft_threshold]}"
      lines << "  full_text_domain: #{yaml_quote(data[:full_text_domain])}"
      lines << ''
    end

    # URL nastaveni pro non-zpravobot Twitter zdroje
    if data[:twitter_url_domain]
      domain = data[:twitter_url_domain]
      lines << '# URL úprava odkazů (přepisuje platformní defaults)'
      lines << 'url:'
      lines << "  replace_to: \"https://#{domain}/\""
      lines << '  replace_from:'
      lines << '    - "https://twitter.com/"'
      lines << '    - "https://x.com/"'
      lines << '    - "https://nitter.net/"'
      lines << ''
    end

    # Nitter Processing (jen pro Twitter)
    if data[:platform] == 'twitter'
      lines << '# Nitter processing (Tier 2)'
      lines << 'nitter_processing:'
      lines << "  enabled: #{data[:nitter_processing_enabled].nil? ? true : data[:nitter_processing_enabled]}"
      lines << ''
    end

    # Thread Handling (pro Twitter/Bluesky)
    if %w[twitter bluesky].include?(data[:platform])
      lines << '# Vlákna'
      lines << 'thread_handling:'
      lines << "  enabled: #{data[:thread_handling_enabled].nil? ? true : data[:thread_handling_enabled]}"
      lines << ''
    end

    # Formatting (pro Twitter/Bluesky - source_name + volitelne url_domain)
    has_source_name = data[:source_name] && %w[twitter bluesky].include?(data[:platform])
    has_url_domain = !!data[:twitter_url_domain]
    if has_source_name || has_url_domain
      lines << '# Formátování'
      lines << 'formatting:'
      lines << "  source_name: #{yaml_quote(data[:source_name])}" if has_source_name
      if has_url_domain
        domain = data[:twitter_url_domain]
        lines << "  url_domain: #{yaml_quote(domain)}"
        lines << '  rewrite_domains:'
        lines << '    - "twitter.com"'
        lines << '    - "x.com"'
        lines << '    - "xn.zpravobot.news"'
        lines << '    - "xcancel.com"'
        lines << '    - "nitter.net"'
      end
      lines << ''
    end

    # Scheduling
    lines << '# Plánování (interval se řídí prioritou: high=5min, normal=20min, low=55min)'
    lines << 'scheduling:'
    lines << "  priority: #{data[:priority] || 'normal'}"
    lines << "  max_posts_per_run: #{data[:max_posts_per_run] || 10}"
    lines << ''

    # Filtering
    lines << '# Filtrování (pro pokročilé filtry typu OR/regex upravte YAML ručně)'
    lines << 'filtering:'

    all_banned_phrases = (data[:banned_phrases] || []) + rssapp_banned_phrases(data)

    if all_banned_phrases.any?
      lines << '  banned_phrases:'
      all_banned_phrases.uniq.each { |phrase| lines << "    - #{yaml_quote(phrase)}" }
    else
      lines << '  banned_phrases: []'
    end
    lines << '  required_keywords: []'

    if %w[twitter bluesky].include?(data[:platform])
      lines << "  skip_replies: #{data[:skip_replies].nil? ? true : data[:skip_replies]}"
      lines << "  skip_retweets: #{data[:skip_retweets].nil? ? false : data[:skip_retweets]}"
    end
    lines << ''

    # Content (for RSS/YouTube)
    if %w[rss youtube].include?(data[:platform])
      lines << '# Obsah'
      lines << 'content:'

      content_mode = data[:content_mode] || 'text'
      mode_settings = CONTENT_MODES[content_mode]

      lines << "  show_title_as_content: #{mode_settings[:show_title_as_content]}"
      lines << "  combine_title_and_content: #{mode_settings[:combine_title_and_content]}"

      if data[:platform] == 'youtube'
        lines << "  include_thumbnail: #{data[:include_thumbnail].nil? ? true : data[:include_thumbnail]}"
      end
      lines << ''
    end

    # Mentions (YouTube only, if enabled)
    if data[:platform] == 'youtube' && data[:youtube_mentions_enabled]
      lines << '# Transformace @zmínek na odkazy'
      lines << 'mentions:'
      lines << '  type: prefix'
      lines << '  value: "https://youtube.com/@"'
      lines << ''
    end

    # Profile sync
    # Plain RSS = rss source, který není facebook/instagram subplatforma
    plain_rss = data[:platform] == 'rss' &&
                !%w[facebook instagram].include?(data[:rss_source_type].to_s)

    show_profile_sync = data[:platform] == 'twitter' ||
                        (data[:platform] == 'bluesky' && data[:bluesky_source_type] != 'feed') ||
                        (data[:platform] == 'rss' && data[:rss_source_type] == 'facebook' && data[:handle])

    if plain_rss
      # Social profile se zjistí až po vytvoření účtu skriptem fetch_rss_social_profiles.rb
      lines << '# Synchronizace profilu'
      lines << 'profile_sync:'
      lines << '  enabled: false  # Doplnit social_profile skriptem fetch_rss_social_profiles.rb'
      lines << ''
    elsif show_profile_sync
      lines << '# Synchronizace profilu'
      lines << 'profile_sync:'
      lines << "  enabled: #{data[:profile_sync_enabled]}"
      if data[:profile_sync_enabled]
        lines << "  sync_avatar: #{data[:sync_avatar].nil? ? true : data[:sync_avatar]}"
        lines << "  sync_banner: #{data[:sync_banner].nil? ? true : data[:sync_banner]}"
        lines << "  sync_bio: #{data[:sync_bio].nil? ? true : data[:sync_bio]}"
        lines << "  sync_fields: #{data[:sync_fields].nil? ? true : data[:sync_fields]}"
        lines << "  language: #{data[:language] || 'cs'}"
        lines << "  retention_days: #{data[:retention_days] || 90}"
      end
      lines << ''
    elsif data[:platform] == 'bluesky' && data[:bluesky_source_type] == 'feed'
      lines << '# Synchronizace profilu (feed nemá vlastní profil)'
      lines << 'profile_sync:'
      lines << '  enabled: false'
      lines << ''
    end

    # Processing - with RSS.app replacements for FB/IG
    lines << '# Zpracování obsahu'
    lines << 'processing:'

    if rssapp_source?(data)
      lines << '  content_replacements:'
      RSSAPP_CONTENT_REPLACEMENTS.each do |repl|
        lines << "    - { pattern: #{yaml_quote(repl[:pattern])}, replacement: #{yaml_quote(repl[:replacement])}, flags: #{yaml_quote(repl[:flags])}, literal: #{repl[:literal]} }"
      end
    else
      lines << '  content_replacements: []'
    end
    if data[:url_domain_fixes]&.any?
      lines << '  url_domain_fixes:'
      data[:url_domain_fixes].each { |domain| lines << "    - #{yaml_quote(domain)}" }
    else
      lines << '  url_domain_fixes: []'
    end

    lines.join("\n") + "\n"
  end

  def generate_mastodon_account_yaml
    acc = @new_mastodon_account
    lines = []
    lines << ''
    lines << "#{acc[:id]}:"
    lines << "  token: #{yaml_quote(acc[:token])}"
    lines << "  instance: #{yaml_quote(acc[:instance])}" if acc[:instance] != DEFAULT_INSTANCE
    lines << "  aggregator: #{acc[:aggregator]}"
    if acc[:categories]&.any?
      lines << "  categories: [#{acc[:categories].join(', ')}]"
    end
    lines.join("\n") + "\n"
  end
end
