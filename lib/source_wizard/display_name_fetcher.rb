# frozen_string_literal: true

require_relative '../utils/html_cleaner'

class SourceGenerator
  # Fetch display name from Bluesky profile
  # @param handle [String] Bluesky handle (e.g. "nesestra.bsky.social")
  # @return [String, nil] Display name or nil if failed
  def fetch_bluesky_display_name(handle)
    print "  ⏳ Načítám profil z Bluesky..."

    api_base = (load_global_config_value(:infrastructure, :bluesky_api) || 'https://public.api.bsky.app/xrpc').chomp('/')
    uri = URI("#{api_base}/app.bsky.actor.getProfile")
    uri.query = URI.encode_www_form(actor: handle)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 5
    http.read_timeout = 5

    request = Net::HTTP::Get.new(uri)
    response = http.request(request)

    if response.is_a?(Net::HTTPSuccess)
      data = JSON.parse(response.body)
      display_name = data['displayName']

      if display_name && !display_name.empty?
        puts " ✅"
        puts "  📋 Nalezeno: #{display_name}"
        display_name
      else
        puts " ⚠️  Profil nemá display name"
        nil
      end
    else
      puts " ❌ Nepodařilo se načíst profil (#{response.code})"
      nil
    end
  rescue StandardError => e
    puts " ❌ Chyba: #{e.message}"
    nil
  end

  # Fetch display name from Twitter/Nitter profile
  # @param handle [String] Twitter handle (without @)
  # @param nitter_instance [String] Nitter instance URL
  # @return [String, nil] Display name or nil if failed
  def fetch_twitter_display_name(handle, nitter_instance = nil)
    nitter_url = nitter_instance || ENV['NITTER_INSTANCE'] || load_global_config_value(:nitter, :instance) || 'http://xn.zpravobot.news:8080'
    nitter_url = nitter_url.chomp('/')

    print "  ⏳ Načítám profil z Twitteru/Nitteru..."

    uri = URI("#{nitter_url}/#{handle}")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = 10
    http.read_timeout = 15

    request = Net::HTTP::Get.new(uri.request_uri)
    request['User-Agent'] = 'Zpravobot/1.0 (+https://zpravobot.news)'

    response = http.request(request)

    if response.is_a?(Net::HTTPSuccess)
      html = response.body.force_encoding('UTF-8')

      # Extract display name using profile-card-fullname pattern
      if html =~ /<a[^>]*class="profile-card-fullname"[^>]*>([^<]+)<\/a>/
        display_name = HtmlCleaner.decode_html_entities($1.strip)

        if display_name && !display_name.empty?
          puts " ✅"
          puts "  📋 Nalezeno: #{display_name}"
          return display_name
        end
      end

      # Fallback: try title tag
      if html =~ /<title>([^(@]+)/
        display_name = HtmlCleaner.decode_html_entities($1.strip)
        if display_name && !display_name.empty?
          puts " ✅"
          puts "  📋 Nalezeno (z title): #{display_name}"
          return display_name
        end
      end

      puts " ⚠️  Profil nenalezen nebo nemá display name"
      nil
    else
      puts " ❌ Nepodařilo se načíst profil (#{response.code})"
      nil
    end
  rescue StandardError => e
    puts " ❌ Chyba: #{e.message}"
    nil
  end

  # Fetch Bluesky feed name from API
  # @param feed_url [String] Feed URL (bsky.app/profile/.../feed/...)
  # @return [String, nil] Feed display name or nil
  def fetch_bluesky_feed_name(feed_url)
    return nil unless feed_url =~ %r{bsky\.app/profile/([^/]+)/feed/([^/?]+)}
    handle = $1
    rkey = $2

    print "  ⏳ Načítám info o feedu..."

    begin
      # Resolve handle to DID
      api_base = (load_global_config_value(:infrastructure, :bluesky_api) || 'https://public.api.bsky.app/xrpc').chomp('/')
      resolve_uri = URI("#{api_base}/com.atproto.identity.resolveHandle?handle=#{handle}")
      resolve_response = Net::HTTP.get_response(resolve_uri)
      return nil unless resolve_response.is_a?(Net::HTTPSuccess)

      did = JSON.parse(resolve_response.body)['did']
      return nil unless did

      # Get feed info
      feed_uri = "at://#{did}/app.bsky.feed.generator/#{rkey}"
      info_uri = URI("#{api_base}/app.bsky.feed.getFeedGenerator")
      info_uri.query = URI.encode_www_form(feed: feed_uri)

      info_response = Net::HTTP.get_response(info_uri)
      return nil unless info_response.is_a?(Net::HTTPSuccess)

      data = JSON.parse(info_response.body)
      name = data.dig('view', 'displayName')

      if name
        puts " ✅"
        name
      else
        puts " ⚠️  Feed nemá název"
        nil
      end
    rescue StandardError => e
      puts " ❌ #{e.message}"
      nil
    end
  end

  # Get display name for source (auto-fetch or manual)
  # @param data [Hash] Source data with :platform and :handle
  # @return [String] Display name to use
  def get_source_display_name(data)
    fetched_name = nil

    case data[:platform]
    when 'bluesky'
      fetched_name = fetch_bluesky_display_name(data[:handle])
    when 'twitter'
      fetched_name = fetch_twitter_display_name(data[:handle])
    end

    # Fallback: handle bez domeny
    fallback_name = data[:handle].to_s
                      .gsub('.bsky.social', '')
                      .gsub(/^@/, '')

    if fetched_name
      ask("Jméno v mentions", default: fetched_name, required: true)
    else
      ask("Jméno v mentions", default: fallback_name, required: true)
    end
  end
end
