# frozen_string_literal: true

# Universal Post Formatter
# ========================
#
# Sjednocený formatter pro všechny platformy (Twitter, Bluesky, RSS, YouTube).
# Podporuje prefix_post_text, tier 3 fallback s read_more indikátory.
#
# Výstupní formáty:
#
# === Posty BEZ headeru (Regular, Thread, Video, RSS, YouTube) ===
#   [prefix_post_text if != "\n"]{text}\n{url_prefix}{url}
#
# === Posty S headerem (Repost, Quote) ===
#   {header}\n{prefix_post_text}{text}\n{url_prefix}{url}
#
# === Tier 3 (truncated fallback) ===
#   url_prefix = read_more_prefix (non-video) nebo video_read_more_prefix (video)
#

require_relative '../utils/hash_helpers'
require_relative '../utils/format_helpers'

module Formatters
  # Default Twitter URL domain and rewrite domains
  # Sourced from config/global.yml twitter section; these are compile-time fallbacks
  TWITTER_URL_DOMAIN = 'xcancel.com'
  TWITTER_REWRITE_DOMAINS = %w[twitter.com x.com nitter.net].freeze

  class UniversalFormatter
    # Default configuration (can be overridden per-source)
    DEFAULTS = {
      # === Prefixes ===
      prefix_repost: '🔁',
      prefix_quote: '💬',
      prefix_thread: '🧵',
      prefix_video: '🎬',
      prefix_post_text: "\n",           # Prefix před textem (za headerem)
      prefix_post_url: "\n",            # Prefix před URL (+ hardcoded \n = prázdný řádek)
      
      # === Tier 3 Truncation Indicators ===
      read_more_prefix: "\n📖➡️ ",       # Pro truncated non-video posty
      video_read_more_prefix: "\n🎬 + 📖➡️ ",  # Pro truncated video posty
      
      # === Self-reference ===
      prefix_self_reference: 'svůj post',
      language: 'cs',
      self_reference_texts: {
        'cs' => 'svůj post',
        'sk' => 'vlastný príspevok',
        'en' => 'own post'
      },
      
      # === Mentions ===
      mentions: {
        type: 'none',
        value: ''
      },
      
      # === URLs ===
      url_domain: nil,
      rewrite_domains: [],
      move_url_to_end: false,
      include_post_url_for_regular: true,  # Přidat post URL pro regular posty bez link card
      
      # === Content ===
      max_length: 500,
      include_quoted_text: false,
      quoted_text_max_chars: 80,
      
      # === RSS/YouTube specific ===
      show_title_as_content: false,
      combine_title_and_content: false,
      title_separator: ' — ',
      
      # === Source ===
      source_name: nil,

      # === Author Header (for feed sources) ===
      show_author_header: false,
      platform_emoji: nil
    }.freeze

    # Platform-specific defaults
    PLATFORM_DEFAULTS = {
      twitter: {
        prefix_repost: '𝕏🔁',
        prefix_quote: '𝕏💬',
        prefix_post_text: "\n",
        prefix_post_url: "\n",
        url_domain: TWITTER_URL_DOMAIN,
        rewrite_domains: TWITTER_REWRITE_DOMAINS,
        mentions: { type: 'none', value: '' },  # Bez URL transformace (kvůli náhledům)
        include_post_url_for_regular: false  # Twitter: URL jen s link card nebo Tier 3
      },
      bluesky: {
        prefix_repost: '🦋🔁',
        prefix_quote: '🦋💬',
        prefix_post_text: "\n",
        prefix_post_url: "\n",
        mentions: { type: 'none', value: '' },  # Bez URL transformace (kvůli náhledům)
        include_post_url_for_regular: false  # Bluesky: URL jen z link card v textu
      },
      rss: {
        prefix_post_text: '',           # Prázdný - RSS nemá header
        prefix_post_url: "\n",
        move_url_to_end: true
        # include_post_url_for_regular: true (default)
      },
      youtube: {
        prefix_post_text: '',           # Prázdný - YouTube nemá header
        prefix_post_url: "\n📺 ",       # Emoji prefix pro video URL
        combine_title_and_content: true,
        title_separator: ' — ',
        mentions: { type: 'none', value: '' }  # Bez URL transformace (kvůli náhledům)
        # include_post_url_for_regular: true (default)
      }
    }.freeze

    def initialize(config = {})
      @config = build_config(config)
    end

    # Main entry point
    # @param post [Post] Normalized post object
    # @param source_config [Hash] Optional source-specific config overrides
    # @return [String] Formatted text for Mastodon
    def format(post, source_config = {})
      config = @config.merge(HashHelpers.symbolize_keys(source_config))
      
      case
      when post.is_repost
        format_repost(post, config)
      when post.is_quote
        format_quote(post, config)
      when post.respond_to?(:is_thread_post) && post.is_thread_post
        format_thread(post, config)
      when needs_title_handling?(post, config)
        format_with_title(post, config)
      else
        format_regular(post, config)
      end
    end

    private

    # ===========================================
    # Post Type Formatters
    # ===========================================

    # Regular post (bez headeru, nebo s author headerem pro feed sources)
    # Format: [prefix_post_text if != "\n"]{text}\n{url_prefix}{url}
    # With author header: {author_header}\n{prefix_post_text}{text}\n{url_prefix}{url}
    def format_regular(post, config)
      parts = []

      # Author header pro feed sources
      has_author_header = false
      if config[:show_author_header] && post.respond_to?(:author) && post.author
        author_header = build_author_header(post.author, config)
        if author_header
          parts << author_header
          has_author_header = true
        end
      end

      # Prefix před textem:
      # - S author headerem: vždy přidat (odděluje header od textu)
      # - Bez headeru: přeskočit pokud je pouze "\n"
      text_prefix = if has_author_header
        config[:prefix_post_text]
      elsif should_include_text_prefix?(config)
        config[:prefix_post_text]
      else
        ''
      end

      text = clean_text(post.text)
      text = format_mentions(text, config, skip: post.author&.username)
      text = rewrite_urls(text, config)
      text = move_url_to_end(text) if config[:move_url_to_end]
      
      # Video handling
      if post.respond_to?(:has_video) && post.has_video
        return format_video_post(post, text, text_prefix, config)
      end
      
      parts << "#{text_prefix}#{text}" unless text.empty?
      
      # URL logic:
      # 1. Link card → vždy přidat
      # 2. Tier 3 (force_read_more) → přidat s read_more prefixem
      # 3. include_post_url_for_regular: true → přidat post URL (Bluesky, RSS)
      # 4. include_post_url_for_regular: false → žádná URL (Twitter Tier 1/2)
      link_url = extract_link_card_url(post)
      
      if link_url
        # S link card: přidat URL
        compose_output(parts, link_url, config, post: post)
      elsif force_read_more?(post)
        # Tier 3: truncated, přidat URL s read_more
        url = rewrite_urls(post.url, config)
        compose_output(parts, url, config, post: post)
      elsif config[:include_post_url_for_regular]
        # Ostatní platformy (Bluesky, RSS): přidat post URL
        url = rewrite_urls(post.url, config)
        compose_output(parts, url, config, post: post)
      else
        # Twitter Tier 1/2 bez link card: žádná URL
        parts.join("\n")
      end
    end

    # Repost (s headerem)
    # Format: {header}\n{prefix_post_text}{text}\n{url_prefix}{url}
    def format_repost(post, config)
      parts = []
      
      # Header: "Source 𝕏🔁 https://xcancel.com/author:"
      header = build_header(
        source: config[:source_name] || post.reposted_by || 'unknown',
        prefix: config[:prefix_repost],
        target: post.author&.username,
        is_self: self_repost?(post),
        config: config
      )
      parts << header
      
      # Content s prefix_post_text (vždy, odděluje header od textu)
      text = clean_text(post.text)
      text = remove_rt_prefix(text)
      text = format_mentions(text, config, skip: post.author&.username)
      text = rewrite_urls(text, config)
      
      unless text.empty?
        parts << "#{config[:prefix_post_text]}#{text}"
      end
      
      # Video handling
      if post.respond_to?(:has_video) && post.has_video
        return format_video_with_header(parts, post, config)
      end
      
      link_url = extract_link_card_url(post)
      compose_output(parts, link_url, config, post: post, source_url: post.url)
    end

    # Quote (s headerem)
    # Format: {header}\n{prefix_post_text}{text}\n{url_prefix}{post_url}
    def format_quote(post, config)
      parts = []
      
      quoted_author = extract_quoted_author(post.quoted_post)
      
      # Header: "Source 𝕏💬 https://xcancel.com/quoted_author:"
      header = build_header(
        source: config[:source_name] || post.author&.username || 'unknown',
        prefix: config[:prefix_quote],
        target: quoted_author,
        is_self: self_quote?(post, quoted_author),
        config: config
      )
      parts << header
      
      # Comment text s prefix_post_text
      text = clean_text(post.text)
      text = format_mentions(text, config, skip: post.author&.username)
      text = rewrite_urls(text, config)
      
      unless text.empty?
        parts << "#{config[:prefix_post_text]}#{text}"
      end
      
      # Post URL (link na původní post, ne na quotovaný)
      post_url = rewrite_urls(post.url, config)

      compose_output(parts, post_url, config, post: post)
    end

    # Thread post (bez headeru, s indikátorem)
    # Format: [prefix_post_text if != "\n"]{prefix_thread} {text}\n{url_prefix}{url}
    def format_thread(post, config)
      parts = []
      
      # Prefix před textem (přeskočit pokud je pouze "\n")
      text_prefix = should_include_text_prefix?(config) ? config[:prefix_post_text] : ''
      
      # Thread indicator
      indicator = build_thread_indicator(post, config)
      
      text = clean_text(post.text)
      text = format_mentions(text, config, skip: post.author&.username)
      text = rewrite_urls(text, config)
      
      if indicator
        parts << "#{text_prefix}#{indicator} #{text}"
      else
        parts << "#{text_prefix}#{text}" unless text.empty?
      end
      
      link_url = extract_link_card_url(post)
      compose_output(parts, link_url, config, post: post, source_url: post.url)
    end

    # RSS/YouTube post s title (bez headeru)
    # Format: [prefix_post_text if != "\n"]{title}{separator}{content}\n{url_prefix}{url}
    def format_with_title(post, config)
      parts = []
      
      # Prefix před textem (přeskočit pokud je pouze "\n")
      text_prefix = should_include_text_prefix?(config) ? config[:prefix_post_text] : ''
      
      title = post.title.to_s.strip
      content = clean_text(post.text).strip  # Strip pro odstranění leading/trailing newlines (např. po content_replacements)
      
      text = if config[:show_title_as_content]
        title
      elsif config[:combine_title_and_content] && !title.empty? && !content.empty?
        # Zkontrolovat duplicitu title/content před spojením
        if title_content_duplicate?(title, content)
          # Vrátit delší verzi
          title.length >= content.length ? title : content
        else
          "#{title}#{config[:title_separator]}#{content}"
        end
      else
        content.empty? ? title : content
      end
      
      text = format_mentions(text, config)
      text = rewrite_urls(text, config)
      text = move_url_to_end(text) if config[:move_url_to_end]
      
      parts << "#{text_prefix}#{text}" unless text.empty?
      compose_output(parts, post.url, config, post: post)
    end

    # ===========================================
    # Video Formatting
    # ===========================================

    # Video post bez headeru
    # Tier 1/2: {text}\n\n🎬 {post_url}
    # Tier 3: {text}\n\n🎬 + 📖➡️ {post_url}
    def format_video_post(post, text, text_prefix, config)
      parts = []
      parts << "#{text_prefix}#{text}" unless text.empty?

      video_url = rewrite_urls(post.url, config)

      if force_read_more?(post)
        # Tier 3: truncated video
        url_prefix = config[:video_read_more_prefix] || "\n🎬 + 📖➡️ "
      else
        # Tier 1/2: video s prefixem
        url_prefix = "\n#{config[:prefix_video]} "
      end

      # Signal that formatter already added video URL (prevents PostProcessor duplicate)
      if post.respond_to?(:raw) && post.raw.is_a?(Hash)
        post.raw[:video_url_added] = true
      end

      # Hardcoded \n + url_prefix = prázdný řádek před URL
      if parts.empty?
        "#{config[:prefix_video]} #{video_url}"
      else
        "#{parts.join}\n#{url_prefix}#{video_url}"
      end
    end

    # Video post s headerem (repost)
    def format_video_with_header(parts, post, config)
      video_url = rewrite_urls(post.url, config)

      if force_read_more?(post)
        # Tier 3: truncated video
        url_prefix = config[:video_read_more_prefix] || "\n🎬 + 📖➡️ "
      else
        # Tier 1/2: video s prefixem
        url_prefix = "\n#{config[:prefix_video]} "
      end

      # Signal that formatter already added video URL (prevents PostProcessor duplicate)
      if post.respond_to?(:raw) && post.raw.is_a?(Hash)
        post.raw[:video_url_added] = true
      end

      # Hardcoded \n + url_prefix = prázdný řádek před URL
      "#{parts.join("\n")}\n#{url_prefix}#{video_url}"
    end

    # ===========================================
    # Header Building
    # ===========================================

    def build_header(source:, prefix:, target:, is_self:, config:)
      target_display = if is_self
        self_reference_text(config)
      else
        "@#{target}"  # Plain @username, bez URL transformace (kvůli náhledům)
      end
      
      "#{source} #{prefix} #{target_display}:"
    end

    # Build author header for feed sources (regular posts)
    # Format: "{display_name} (@{handle}) {platform_emoji}:"
    # @param author [Author] Post author
    # @param config [Hash] Configuration
    # @return [String, nil] Header line or nil
    def build_author_header(author, config)
      display_name = author.display_name || author.username
      handle = author.username
      return nil unless handle

      platform_emoji = config[:platform_emoji] || ''

      emoji_part = platform_emoji.empty? ? '' : " #{platform_emoji}"
      "#{display_name} (@#{handle})#{emoji_part}:"
    end

    def build_thread_indicator(post, config)
      return nil unless config.dig(:thread_handling, :show_indicator) != false

      # Pouze prefix emoji, bez pozice/total
      # U IFTTT webhooků nevíme kolik postů thread bude mít
      config[:prefix_thread]
    end

    # ===========================================
    # Mention Formatting
    # ===========================================

    def format_mentions(text, config, skip: nil)
      return '' if text.nil? || text.empty?
      
      mentions_config = config[:mentions] || {}
      return text if mentions_config[:type] == 'none' || mentions_config[:value].to_s.empty?
      
      skip_normalized = skip&.to_s&.gsub(/^@/, '')&.downcase
      
      text.gsub(/(?<![.\w\/])@(\w+)/) do |match|
        username = $1
        if skip_normalized && username.downcase == skip_normalized
          match
        else
          format_single_mention(username, mentions_config)
        end
      end
    end

    def format_single_mention(username, mentions_config)
      return "@#{username}" unless mentions_config
      
      type = mentions_config[:type]&.to_s || 'none'
      value = mentions_config[:value]&.to_s || ''
      
      case type
      when 'prefix'
        "#{value}#{username}"
      when 'suffix'
        "@#{username} (#{value}#{username})"
      when 'domain_suffix'
        "@#{username}@#{value}"
      when 'domain_suffix_with_local'
        local_handles = mentions_config[:local_handles] || {}
        local_instance = mentions_config[:local_instance].to_s
        key = username.downcase
        if !local_instance.empty? && local_handles.key?(key)
          "@#{local_handles[key]}@#{local_instance}"
        else
          "@#{username}@#{value}"
        end
      else
        "@#{username}"
      end
    end

    # ===========================================
    # URL Handling
    # ===========================================

    def rewrite_urls(text, config)
      return text if text.nil? || text.empty?
      
      target = config[:url_domain]
      return text unless target
      
      domains = config[:rewrite_domains] || []
      return text if domains.empty?
      
      result = text.dup
      domains.each do |domain|
        pattern = %r{https?://(?:www\.)?#{Regexp.escape(domain)}/}i
        result.gsub!(pattern, "https://#{target}/")
      end
      
      result
    end

    def move_url_to_end(text)
      return text if text.nil? || text.empty?
      
      if text =~ /^(https?:\/\/\S+)\s+(.+)$/m
        "#{$2.strip}\n\n#{$1}"
      else
        text
      end
    end

    def extract_link_card_url(post)
      return nil unless post.respond_to?(:media) && post.media
      
      link_card = post.media.find { |m| m.respond_to?(:type) && m.type == 'link_card' }
      link_card&.url
    end

    # ===========================================
    # Output Composition
    # ===========================================

    # Compose final output with appropriate URL prefix
    # @param parts [Array] Text parts
    # @param url [String] URL to append
    # @param config [Hash] Configuration
    # @param post [Post] Original post (for tier detection)
    # @param source_url [String] Optional fallback URL
    def compose_output(parts, url, config, post: nil, source_url: nil)
      content = parts.compact.reject { |p| p.to_s.strip.empty? }.join("\n")
      
      # Rewrite source_url if provided (for repost/thread fallback)
      source_url = rewrite_urls(source_url, config) if source_url
      
      final_url = url || source_url
      
      if final_url && !final_url.empty?
        # URL deduplication: skip if URL already present in content
        if url_already_in_content?(content, final_url)
          return content
        end
        
        url_prefix = select_url_prefix(post, config)
        # Hardcoded \n + url_prefix = prázdný řádek před URL
        content.empty? ? final_url : "#{content}\n#{url_prefix}#{final_url}"
      else
        content
      end
    end

    # ===========================================
    # URL Deduplication
    # ===========================================

    # Check if URL is already present in content
    # Uses normalized comparison to handle variations like trailing slashes, query params
    # @param content [String] Text content to check
    # @param url [String] URL to look for
    # @return [Boolean] true if URL is already in content
    def url_already_in_content?(content, url)
      return false if content.nil? || content.empty?
      return false if url.nil? || url.empty?
      
      normalized_url = normalize_url_for_dedup(url)
      return false if normalized_url.empty?
      
      # Find all URLs in content
      content_urls = content.scan(%r{https?://[^\s]+})
      return false if content_urls.empty?
      
      # Check if any existing URL matches
      content_urls.any? do |content_url|
        normalize_url_for_dedup(content_url) == normalized_url
      end
    end

    # Normalize URL for deduplication comparison
    # Removes: protocol, trailing slash, query params, trailing punctuation
    # @param url [String] URL to normalize
    # @return [String] Normalized URL for comparison
    def normalize_url_for_dedup(url)
      return '' if url.nil? || url.empty?
      
      normalized = url.downcase
      # Remove trailing punctuation (., !, ?, etc.)
      normalized = normalized.sub(/[.,;:!?…]+$/, '')
      # Remove query params
      normalized = normalized.sub(/\?.*$/, '')
      # Remove protocol
      normalized = normalized.sub(%r{^https?://}, '')
      # Remove www. prefix
      normalized = normalized.sub(/^www\./, '')
      # Remove trailing slash
      normalized = normalized.sub(%r{/+$}, '')
      normalized
    end

    # Select appropriate URL prefix based on tier
    # @param post [Post] Post object (may contain tier info in raw)
    # @param config [Hash] Configuration
    # @return [String] URL prefix to use
    def select_url_prefix(post, config)
      if force_read_more?(post)
        # Tier 3: truncated data - use read_more_prefix
        config[:read_more_prefix] || "\n📖➡️ "
      else
        # Normal: use standard prefix
        prefix = config[:prefix_post_url].to_s
        prefix.empty? ? "\n" : prefix
      end
    end

    # ===========================================
    # Tier Detection
    # ===========================================

    # Check if post requires read_more indicator (Tier 3 fallback)
    # @param post [Post] Post object
    # @return [Boolean] true if post is truncated and needs read_more
    def force_read_more?(post)
      return false unless post
      return false unless post.respond_to?(:raw) && post.raw.is_a?(Hash)
      
      post.raw[:force_read_more] == true || post.raw['force_read_more'] == true
    end

    # ===========================================
    # Text Prefix Logic
    # ===========================================

    # Determine if prefix_post_text should be included
    # Skip if it's just "\n" (avoid empty line at start of headerless posts)
    # @param config [Hash] Configuration
    # @return [Boolean] true if prefix should be included
    def should_include_text_prefix?(config)
      prefix = config[:prefix_post_text].to_s
      !prefix.empty? && prefix != "\n"
    end

    # ===========================================
    # Text Cleaning
    # ===========================================

    def clean_text(text)
      FormatHelpers.clean_text(text)
    end

    def remove_rt_prefix(text)
      return '' if text.nil?
      
      text.sub(/^RT\s+@\w+:\s*/i, '')
          .sub(/^RT\s+https?:\/\/[^\s]+\/(\w+):\s*/i, '')
          .strip
    end

    # ===========================================
    # Title/Content Duplicate Detection
    # ===========================================

    # Zkontroluje zda title a content jsou duplicitní/podobné
    # Používá se pro Facebook Reels kde RSS.app vrací téměř identický title a description
    # @param title [String] Title
    # @param content [String] Content/description
    # @return [Boolean] true pokud jsou duplicitní
    def title_content_duplicate?(title, content)
      return false if title.nil? || content.nil?
      return false if title.empty? || content.empty?
      
      # Normalizace pro porovnání
      title_norm = normalize_for_duplicate_check(title)
      content_norm = normalize_for_duplicate_check(content)
      
      # Přesná shoda
      return true if title_norm == content_norm
      
      # Jeden je prefix druhého (zkrácená verze)
      shorter, longer = [title_norm, content_norm].sort_by(&:length)
      min_match = (shorter.length * 0.7).to_i
      return true if min_match >= 15 && longer.start_with?(shorter[0...min_match])
      
      # Vysoká podobnost (word overlap)
      title_words = title_norm.split(/\s+/).reject { |w| w.length < 3 }
      content_words = content_norm.split(/\s+/).reject { |w| w.length < 3 }
      
      return false if title_words.length < 3 || content_words.length < 3
      
      intersection = (title_words & content_words).size
      union = (title_words | content_words).size
      
      return false if union.zero?
      
      similarity = intersection.to_f / union
      similarity >= 0.6  # 60% threshold
    end

    # Normalizace textu pro porovnání duplicit
    def normalize_for_duplicate_check(text)
      normalized = text.dup.downcase
      # Odstranit ellipsis
      normalized.gsub!(/[…]|\.{3,}/, '')
      # Odstranit URL
      normalized.gsub!(%r{https?://\S+}, '')
      # Odstranit hashtags
      normalized.gsub!(/#\S+/, '')
      # Normalizovat whitespace
      normalized.gsub!(/\s+/, ' ')
      normalized.strip
    end

    # ===========================================
    # Self-reference Detection
    # ===========================================

    def self_reference_text(config)
      lang = config[:language]&.to_s || 'cs'
      texts = config[:self_reference_texts] || DEFAULTS[:self_reference_texts]
      texts[lang] || texts['cs'] || config[:prefix_self_reference] || 'svůj post'
    end

    def self_repost?(post)
      return false unless post.respond_to?(:reposted_by) && post.respond_to?(:author)
      post.author&.username&.downcase == post.reposted_by&.downcase
    end

    def self_quote?(post, quoted_author)
      return false unless post.respond_to?(:author)
      post.author&.username&.downcase == quoted_author&.downcase
    end

    def extract_quoted_author(quoted_post)
      return 'unknown' unless quoted_post
      
      author = quoted_post[:author] || quoted_post['author']
      case author
      when Hash
        author[:username] || author['username'] || 'unknown'
      when String
        author
      else
        author.respond_to?(:username) && author.username ? author.username : 'unknown'
      end
    end

    # ===========================================
    # Helpers
    # ===========================================

    def needs_title_handling?(post, config)
      return false unless post.respond_to?(:title) && post.title
      return false if post.title.to_s.strip.empty?
      
      config[:show_title_as_content] || config[:combine_title_and_content]
    end

    def build_config(config)
      result = DEFAULTS.dup
      
      platform = config[:platform]&.to_sym
      if platform && PLATFORM_DEFAULTS[platform]
        result = HashHelpers.deep_merge(result, PLATFORM_DEFAULTS[platform])
      end

      HashHelpers.deep_merge(result, HashHelpers.symbolize_keys(config))
    end
  end
end
