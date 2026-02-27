# frozen_string_literal: true

# Twitter Tweet Processor — Unified Processing Layer
# ==================================================
#
# Unifikovaná vrstva pro zpracování Twitter tweetů z obou vstupních kanálů:
#   - IFTTT webhook (real-time push)       → volá IftttQueueProcessor
#   - Nitter RSS polling (periodický pull) → volá Orchestrator::Runner
#
# Oba kanály předají:
#   post_id + username + source_config [+ fallback_post]
# a tato třída zajistí identickou Tier logiku, threading a PostProcessor.
#
# Tier logika:
#   nitter_processing.enabled: true  → Tier 2 (Nitter fetch + retry)
#   nitter_processing.enabled: false → fallback_post přímo (bez Nitter fetche)
#
# Fallback řetězec (při nitter_enabled: true):
#   Nitter (3x retry + exponential backoff)
#     → Syndication API (Tier 3.5)
#       → fallback_post (Tier 3)
#         → skip (nil → :skipped)
#
# Threading:
#   thread_handling.enabled: true  → TwitterThreadProcessor (advanced, per-source lazy cache)
#   thread_handling.enabled: false → ThreadingSupport (basic: cache + DB lookup)
#
# Použití:
#   processor = Processors::TwitterTweetProcessor.new(
#     state_manager: sm,
#     config_loader: cl,
#     nitter_instance: 'http://xn.zpravobot.news:8080'
#   )
#   result = processor.process(
#     post_id: '123456789',
#     username: 'example',
#     source_config: config,
#     fallback_post: rss_post   # nil pro IFTTT pokud Tier 1 nebyl potřeba
#   )
#   # => :published | :skipped | :failed

require_relative '../support/loggable'
require_relative '../support/threading_support'
require_relative '../adapters/twitter_adapter'
require_relative '../services/syndication_media_fetcher'
require_relative '../models/post'
require_relative '../models/author'
require_relative '../models/media'
require_relative 'twitter_thread_processor'
require_relative 'post_processor'

module Processors
  class TwitterTweetProcessor
    include Support::Loggable
    include Support::ThreadingSupport

    RETRY_ATTEMPTS = 3
    RETRY_DELAYS   = [1, 2, 4].freeze   # sekundy, exponential backoff

    # @param state_manager [State::StateManager]  DB state manager (ThreadingSupport + PostProcessor)
    # @param config_loader [Config::ConfigLoader]  Config loader (PostProcessor + publisher credentials)
    # @param nitter_instance [String, nil]  Globální Nitter URL (může být přepsán přes source_config)
    # @param dry_run [Boolean]  Pokud true, přeskočí skutečné publikování
    # @param post_processor [Processors::PostProcessor, nil]  Injektovaný pro testy (jinak lazy-init)
    def initialize(state_manager:, config_loader:, nitter_instance: nil, dry_run: false, post_processor: nil)
      @state_manager    = state_manager
      @config_loader    = config_loader
      @nitter_instance  = nitter_instance || ENV['NITTER_INSTANCE']
      @dry_run          = dry_run
      @_post_processor  = post_processor

      # Per-source cache pro TwitterThreadProcessor (thread_handling.enabled: true)
      @thread_processor_cache = {}

      # In-memory thread cache pro ThreadingSupport (thread_handling.enabled: false)
      @thread_cache = {}
    end

    # Zpracuj jeden tweet přes unifikovanou pipeline
    #
    # @param post_id [String]  Twitter status ID (numerický řetězec)
    # @param username [String]  Twitter handle (bez @)
    # @param source_config [Hash]  Source configuration hash
    # @param fallback_post [Post, nil]  Post z IFTTT/RSS dat (použit jako Tier 3 fallback)
    # @return [Symbol]  :published, :skipped, nebo :failed
    def process(post_id:, username:, source_config:, fallback_post: nil)
      source_id = source_config[:id]
      log_info("[#{source_id}] Processing tweet #{post_id} by @#{username}")

      nitter_enabled = source_config.dig(:nitter_processing, :enabled) != false

      post, in_reply_to_id = if nitter_enabled
        fetch_and_resolve(post_id, username, source_config, fallback_post)
      else
        # Nitter disabled → použij fallback_post přímo
        log_info("[#{source_id}] Nitter disabled → using fallback_post directly")
        if fallback_post
          in_reply = resolve_thread_parent(source_id, fallback_post)
          [fallback_post, in_reply]
        else
          [nil, nil]
        end
      end

      unless post
        log_warn("[#{source_id}] No post available for #{post_id} → skipping")
        return :skipped
      end

      result = post_processor.process(post, source_config, in_reply_to_id: in_reply_to_id)

      if result.published?
        update_thread_cache(source_id, post, result.mastodon_id)
        :published
      elsif result.skipped?
        :skipped
      else
        :failed
      end
    rescue StandardError => e
      log_error("[#{source_config[:id]}] TwitterTweetProcessor error: #{e.message}")
      :failed
    end

    private

    # Tier 2/3.5/3 cascade + threading resolution
    #
    # @return [Array<Post|nil, String|nil>]  [post, in_reply_to_id]
    def fetch_and_resolve(post_id, username, source_config, fallback_post)
      source_id = source_config[:id]

      # Advanced threading: TwitterThreadProcessor reconstructuje chain + detects in_reply_to
      if source_config.dig(:thread_handling, :enabled) == true
        return fetch_with_advanced_threading(post_id, username, source_config, fallback_post)
      end

      # Basic threading: fetch Nitter → resolve parent via ThreadingSupport
      post = fetch_from_nitter_with_retry(post_id, username, source_config)
      if post
        in_reply_to_id = resolve_thread_parent(source_id, post)
        return [post, in_reply_to_id]
      end

      # Nitter selhalo → Syndication fallback (Tier 3.5)
      log_warn("[#{source_id}] Nitter failed → trying Syndication (Tier 3.5)")
      syndication_post = fetch_from_syndication(post_id, username, source_config, fallback_post)
      if syndication_post
        in_reply_to_id = resolve_thread_parent(source_id, syndication_post)
        return [syndication_post, in_reply_to_id]
      end

      # Syndication selhalo → Tier 3 fallback_post
      if fallback_post
        log_warn("[#{source_id}] Syndication failed → using fallback_post (Tier 3)")
        in_reply_to_id = resolve_thread_parent(source_id, fallback_post)
        return [fallback_post, in_reply_to_id]
      end

      log_warn("[#{source_id}] All fetch attempts failed, no fallback_post → skipping #{post_id}")
      [nil, nil]
    end

    # Advanced threading přes TwitterThreadProcessor
    #
    # TwitterThreadProcessor:
    #   1. Fetches Nitter HTML pro aktuální tweet
    #   2. Detects + reconstructs thread chain (publishuje chybějící tweety)
    #   3. Vrací { in_reply_to_id:, html:, is_thread: }
    #
    # Hlavní tweet fetchujeme zvlášť (fetch_from_nitter_with_retry).
    # TODO: Optimalizace — předat thread_result[:html] do parseru a vyhnout se
    #       druhému Nitter fetchi (TwitterThreadProcessor fetch + fetch_single_post = 2x stejná URL)
    #
    # @return [Array<Post|nil, String|nil>]  [post, in_reply_to_id]
    def fetch_with_advanced_threading(post_id, username, source_config, fallback_post)
      source_id = source_config[:id]

      thread_processor = get_thread_processor(source_config)
      thread_result    = thread_processor.process(source_id, post_id, username)
      in_reply_to_id   = thread_result[:in_reply_to_id]

      if thread_result[:is_thread]
        chain_info = thread_result[:chain_length] ? " (chain: #{thread_result[:chain_length]})" : ""
        log_info("[#{source_id}] Thread detected#{chain_info}, in_reply_to: #{in_reply_to_id || 'thread start'}")
      end

      # Fetch main tweet (Nitter → Syndication → fallback_post)
      post = fetch_from_nitter_with_retry(post_id, username, source_config)
      return [post, in_reply_to_id] if post

      log_warn("[#{source_id}] Nitter failed in advanced threading → trying Syndication")
      syndication_post = fetch_from_syndication(post_id, username, source_config, fallback_post)
      return [syndication_post, in_reply_to_id] if syndication_post

      if fallback_post
        log_warn("[#{source_id}] All fetches failed → using fallback_post (Tier 3)")
        return [fallback_post, in_reply_to_id]
      end

      [nil, nil]
    rescue StandardError => e
      log_error("[#{source_config[:id]}] Advanced threading error: #{e.message}")
      [nil, nil]
    end

    # Fetch z Nitteru s exponential backoff retry
    #
    # @return [Post, nil]
    def fetch_from_nitter_with_retry(post_id, username, source_config)
      source_id = source_config[:id]
      adapter   = get_twitter_adapter(username, source_config)

      RETRY_ATTEMPTS.times do |attempt|
        begin
          post = adapter.fetch_single_post(post_id)

          if post
            log_info("[#{source_id}] Nitter fetch OK#{attempt > 0 ? " (attempt #{attempt + 1})" : ""}")
            return post
          end

          if attempt < RETRY_ATTEMPTS - 1
            delay = RETRY_DELAYS[attempt]
            log_warn("[#{source_id}] Nitter returned nil, retry in #{delay}s (attempt #{attempt + 1}/#{RETRY_ATTEMPTS})")
            sleep delay
          end

        rescue StandardError => e
          if attempt < RETRY_ATTEMPTS - 1
            delay = RETRY_DELAYS[attempt]
            log_warn("[#{source_id}] Nitter error: #{e.message}, retry in #{delay}s (attempt #{attempt + 1}/#{RETRY_ATTEMPTS})")
            sleep delay
          else
            log_error("[#{source_id}] Nitter failed after #{RETRY_ATTEMPTS} attempts: #{e.message}")
          end
        end
      end

      nil
    end

    # Fetch z Twitter Syndication API (Tier 3.5 fallback po Nitter failure)
    #
    # @return [Post, nil]
    def fetch_from_syndication(post_id, username, source_config, fallback_post)
      source_id = source_config[:id]
      result    = Services::SyndicationMediaFetcher.fetch(post_id)
      return nil unless result[:success]

      log_info("[#{source_id}] Syndication OK: #{result[:photos].count} photos, video: #{result[:video_thumbnail] ? 'yes' : 'no'}")
      build_syndication_post(post_id, username, source_config, result, fallback_post)
    rescue StandardError => e
      log_error("[#{source_id}] Syndication error: #{e.message}")
      nil
    end

    # Sestav Post z dat Twitter Syndication API
    #
    # Typové příznaky (is_repost, is_reply, is_quote) dědíme z fallback_post pokud je k dispozici —
    # IFTTT/RSS signály jsou autoritativnější pro detekci typu postu.
    #
    # @return [Post]
    def build_syndication_post(post_id, username, source_config, syndication, fallback_post)
      syndi_username = syndication[:username] || username
      display_name   = syndication[:display_name] || syndi_username
      url_domain     = source_config.dig(:url, :replace_to) || 'x.com'
      tweet_url      = "https://#{url_domain}/#{syndi_username}/status/#{post_id}"

      # Media
      media = []
      syndication[:photos].each do |photo_url|
        media << Media.new(type: 'image', url: photo_url, alt_text: '')
      end
      if syndication[:video_thumbnail] && media.empty?
        media << Media.new(type: 'image', url: syndication[:video_thumbnail], alt_text: 'Video thumbnail')
      end

      # Typové příznaky z fallback_post (IFTTT/RSS jsou autoritativnější)
      is_repost   = fallback_post&.is_repost   || false
      is_reply    = fallback_post&.is_reply     || false
      is_quote    = fallback_post&.is_quote     || false
      reposted_by = fallback_post&.reposted_by
      quoted_post = fallback_post&.quoted_post
      has_video   = !syndication[:video_thumbnail].nil? || (fallback_post&.has_video || false)

      # Pro reposts: originální autor z fallback_post; jinak autor ze Syndication
      author = if is_repost && fallback_post&.author
        fallback_post.author
      else
        Author.new(
          username: syndi_username,
          display_name: display_name,
          url: "https://x.com/#{syndi_username}"
        )
      end

      published_at = begin
        syndication[:created_at] ? Time.parse(syndication[:created_at]) : Time.now
      rescue ArgumentError
        Time.now
      end

      ifttt_trigger = fallback_post&.raw.is_a?(Hash) && fallback_post.raw[:ifttt_trigger]

      Post.new(
        id: post_id,
        platform: 'twitter',
        url: tweet_url,
        text: syndication[:text] || '',
        author: author,
        published_at: published_at,
        media: media,
        is_repost: is_repost,
        is_reply: is_reply,
        is_quote: is_quote,
        reposted_by: reposted_by,
        quoted_post: quoted_post,
        has_video: has_video,
        raw: {
          source: 'syndication_fallback',
          tier: 3.5,
          nitter_failed: true,
          ifttt_trigger: ifttt_trigger
        }
      )
    end

    # Získej TwitterAdapter pro daný source (vytvoří nový pokaždé — je to lightweight)
    def get_twitter_adapter(username, source_config)
      nitter_inst = source_config.dig(:source, :nitter_instance) || @nitter_instance
      url_domain  = source_config.dig(:url, :replace_to)

      Adapters::TwitterAdapter.new(
        handle: username,
        nitter_instance: nitter_inst,
        url_domain: url_domain
      )
    end

    # Lazy-init TwitterThreadProcessor per source (jeden singleton per source_id)
    # Sdílí stejnou instanci pro threading cache konzistenci
    def get_thread_processor(source_config)
      source_id = source_config[:id]
      @thread_processor_cache[source_id] ||= build_thread_processor(source_config)
    end

    # Sestav nový TwitterThreadProcessor pro daný source
    # Publisher je potřeba pro publish_chain_tweet (rekonstrukce chybějících tweetů v chainu)
    def build_thread_processor(source_config)
      require_relative '../publishers/mastodon_publisher'

      username    = source_config.dig(:source, :handle)
      nitter_inst = source_config.dig(:source, :nitter_instance) || @nitter_instance
      url_domain  = source_config.dig(:url, :replace_to)

      twitter_adapter = Adapters::TwitterAdapter.new(
        handle: username,
        nitter_instance: nitter_inst,
        url_domain: url_domain
      )

      publisher = build_publisher(source_config)

      TwitterThreadProcessor.new(
        state_manager:   @state_manager,
        twitter_adapter: twitter_adapter,
        publisher:       publisher,
        nitter_instance: nitter_inst,
        url_domain:      url_domain
      )
    end

    # Sestav MastodonPublisher pro daný source
    # Mirroruje logiku PostProcessor#get_publisher
    def build_publisher(source_config)
      account_id = source_config.dig(:target, :mastodon_account)

      # Direct token (z Orchestratoru) má přednost před config_loader
      token = source_config[:_mastodon_token]
      unless token
        account_creds = @config_loader.mastodon_credentials(account_id)
        token = account_creds[:token]
      end

      instance_url = source_config.dig(:target, :mastodon_instance) ||
                     source_config.dig(:mastodon, :instance) ||
                     @config_loader.load_global_config.dig(:mastodon, :instance)

      Publishers::MastodonPublisher.new(
        instance_url: instance_url,
        access_token: token
      )
    end

    # Lazy-init PostProcessor (sdílený napříč všemi process() calls)
    def post_processor
      @_post_processor ||= Processors::PostProcessor.new(
        state_manager: @state_manager,
        config_loader: @config_loader,
        dry_run: @dry_run
      )
    end

  end
end
