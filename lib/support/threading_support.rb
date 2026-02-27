# frozen_string_literal: true

# Threading Support Module
# ========================
# Sdílená logika pro threading support napříč procesory.
# Používá se v Orchestrator::Runner i Webhook::IftttQueueProcessor.
#
# Požadavky na třídu která includuje tento modul:
# - @state_manager [State::StateManager] - pro DB lookup
# - @thread_cache [Hash] - inicializovat jako {} v initialize
#
# Použití:
#   class MyProcessor
#     include Support::ThreadingSupport
#
#     def initialize
#       @state_manager = State::StateManager.new
#       @thread_cache = {}
#     end
#
#     def process(post)
#       parent_id = resolve_thread_parent(source_id, post)
#       # ... publish with parent_id ...
#       update_thread_cache(source_id, post, mastodon_id)
#     end
#   end

module Support
  module ThreadingSupport
    # Resolve Mastodon parent ID for thread continuation
    #
    # Hledá v tomto pořadí:
    # 1. In-memory cache (aktuální run) - pro rychlé propojení v rámci jednoho běhu
    # 2. Database (24h okno) - pro propojení mezi běhy
    #
    # @param source_id [String] Source identifier (e.g., 'vlaboratories')
    # @param post [Post] Post object to check
    # @return [String, nil] Mastodon status ID of parent, or nil
    def resolve_thread_parent(source_id, post)
      return nil unless thread_post?(post)

      # 1. In-memory cache (fast path for same-run threading)
      cached_id = thread_cache_lookup(source_id, post)
      if cached_id
        log_threading("Using cached parent #{cached_id}", source_id)
        return cached_id
      end

      # 2. Database lookup (cross-run threading)
      db_parent = @state_manager.find_recent_thread_parent(source_id)
      if db_parent
        log_threading("Using DB parent #{db_parent}", source_id)
        return db_parent
      end

      log_threading("No parent found (thread start)", source_id)
      nil
    end

    # Update thread cache after successful publish
    #
    # Ukládá mastodon_id pro daného autora, aby následující post ve threadu
    # mohl být správně propojen jako reply.
    #
    # @param source_id [String] Source identifier
    # @param post [Post] Published post
    # @param mastodon_id [String] Mastodon status ID
    def update_thread_cache(source_id, post, mastodon_id)
      return unless mastodon_id

      author_handle = extract_author_handle(post)
      return unless author_handle

      @thread_cache ||= {}
      @thread_cache[source_id] ||= {}
      @thread_cache[source_id][author_handle] = mastodon_id

      log_threading("Cached #{mastodon_id} for @#{author_handle}", source_id)
    end

    # Clear thread cache (e.g., between runs or for testing)
    def clear_thread_cache
      @thread_cache = {}
    end

    # Check if post qualifies for threading
    # @param post [Post] Post to check
    # @return [Boolean] true if this is a thread continuation
    def thread_post?(post)
      post.respond_to?(:is_thread_post) && post.is_thread_post
    end

    private

    # Lookup in thread cache by author
    # @param source_id [String] Source identifier
    # @param post [Post] Post to lookup parent for
    # @return [String, nil] Cached Mastodon status ID or nil
    def thread_cache_lookup(source_id, post)
      return nil unless @thread_cache

      author_handle = extract_author_handle(post)
      return nil unless author_handle

      @thread_cache.dig(source_id, author_handle)
    end

    # Extract author handle from post
    # Supports both Post objects with Author and Hash-based authors
    #
    # @param post [Post] Post object
    # @return [String, nil] Lowercase author handle or nil
    def extract_author_handle(post)
      return nil unless post.respond_to?(:author) && post.author

      author = post.author

      if author.respond_to?(:username)
        # Post.author is an Author object
        author.username.to_s.downcase
      elsif author.is_a?(Hash)
        # Post.author is a Hash (less common)
        (author['username'] || author[:username]).to_s.downcase
      end
    end

    # Log threading activity
    # Tries to use the including class's logging method, falls back to puts
    #
    # @param message [String] Log message (without prefix)
    # @param source_id [String] Source identifier for context
    def log_threading(message, source_id)
      full_message = "[#{source_id}] 🧵 Threading: #{message}"

      if respond_to?(:log_info, true)
        log_info(full_message)
      elsif respond_to?(:log, true)
        log(full_message)
      else
        puts "[#{Time.now.strftime('%H:%M:%S')}] ℹ️  #{full_message}"
      end
    end
  end
end
