# frozen_string_literal: true

require 'digest'
require 'set'
require 'uri'

module Processors
  # Edit Detector for Twitter Posts
  # ================================
  #
  # Detekuje editované tweety na základě textové podobnosti.
  # Twitter umožňuje editaci do 1 hodiny, přičemž vzniká nové status ID.
  # IFTTT zachytí obě verze jako samostatné triggery.
  #
  # Strategie:
  # 1. Původní tweet přijde → uložíme do bufferu, publikujeme
  # 2. Editovaná verze přijde → detekujeme podobnost → UPDATE Mastodon post
  # 3. Obě verze v jednom batch → publikujeme jen novější
  #
  # Použití:
  #   detector = Processors::EditDetector.new(state_manager)
  #   result = detector.check_for_edit(source_id, post_id, username, text)
  #
  #   case result[:action]
  #   when :publish_new
  #     # Normální publikace
  #   when :update_existing
  #     # Update Mastodon post result[:mastodon_id] s novým textem
  #   when :skip_older_version
  #     # Přeskočit - novější verze už v bufferu
  #   end
  #
  class EditDetector
    # Konfigurace
    EDIT_WINDOW = 3600              # 1 hodina v sekundách (Twitter edit window)
    SIMILARITY_THRESHOLD = 0.80    # 80% podobnost pro detekci editu
    EXACT_MATCH_THRESHOLD = 0.98   # 98%+ = téměř identický text
    BUFFER_RETENTION = 7200        # 2 hodiny retence v bufferu

    attr_reader :state_manager, :logger

    def initialize(state_manager, logger: nil)
      @state_manager = state_manager
      @logger = logger
    end

    # Hlavní entry point - zkontrolovat zda je post editovaná verze
    #
    # @param source_id [String] Source/bot identifier
    # @param post_id [String] Twitter status ID
    # @param username [String] Twitter handle
    # @param text [String] Tweet text
    # @param post_timestamp [Time, nil] Tweet creation time (pro určení novější verze)
    # @return [Hash] { action:, original_post_id:, mastodon_id:, similarity: }
    def check_for_edit(source_id, post_id, username, text, post_timestamp: nil)
      normalized_username = normalize_username(username)
      normalized_text = normalize_for_comparison(text)
      text_hash = compute_hash(normalized_text)

      # 1. Najít podobné posty v bufferu
      similar = find_similar_in_buffer(normalized_username, normalized_text, text_hash)

      if similar.nil?
        # Žádný podobný post - normální publikace
        log_debug("No similar post found for @#{normalized_username}/#{post_id}")
        return {
          action: :publish_new,
          original_post_id: nil,
          mastodon_id: nil,
          similarity: 0.0
        }
      end

      # 2. Našli jsme podobný post - rozhodnout co dál
      log_info("Similar post found: #{post_id} ~ #{similar[:post_id]} (#{(similar[:similarity] * 100).round(1)}%)")

      # Určit která verze je novější (vyšší ID = novější u Twitter Snowflake)
      new_is_newer = compare_post_ids(post_id, similar[:post_id]) > 0

      if similar[:mastodon_id]
        # Původní BYL publikován na Mastodon
        if new_is_newer
          # Nový post je novější (editovaná verze) → UPDATE
          {
            action: :update_existing,
            original_post_id: similar[:post_id],
            mastodon_id: similar[:mastodon_id],
            similarity: similar[:similarity]
          }
        else
          # Nový post je STARŠÍ (původní přišel pozdě) → SKIP
          log_info("Skipping older version #{post_id}, newer #{similar[:post_id]} already published")
          {
            action: :skip_older_version,
            original_post_id: similar[:post_id],
            mastodon_id: similar[:mastodon_id],
            similarity: similar[:similarity]
          }
        end
      else
        # Původní NEBYL publikován (oba v jednom batch)
        if new_is_newer
          # Nový je novější → publikovat tento, skip starší
          log_info("Publishing newer version #{post_id}, marking #{similar[:post_id]} as superseded")
          mark_superseded(source_id, similar[:post_id])
          {
            action: :publish_new,
            original_post_id: similar[:post_id],
            mastodon_id: nil,
            similarity: similar[:similarity],
            superseded_post_id: similar[:post_id]
          }
        else
          # Nový je starší → skip tento, novější už v bufferu
          log_info("Skipping older version #{post_id}, newer #{similar[:post_id]} already in buffer")
          {
            action: :skip_older_version,
            original_post_id: similar[:post_id],
            mastodon_id: nil,
            similarity: similar[:similarity]
          }
        end
      end
    end

    # Přidat post do bufferu (volat po publikaci)
    #
    # @param source_id [String] Source/bot identifier
    # @param post_id [String] Twitter status ID
    # @param username [String] Twitter handle
    # @param text [String] Tweet text
    # @param mastodon_id [String, nil] Mastodon status ID (pokud publikováno)
    def add_to_buffer(source_id, post_id, username, text, mastodon_id: nil)
      normalized_text = normalize_for_comparison(text)
      text_hash = compute_hash(normalized_text)

      state_manager.add_to_edit_buffer(
        source_id: source_id,
        post_id: post_id,
        username: normalize_username(username),
        text_normalized: normalized_text,
        text_hash: text_hash,
        mastodon_id: mastodon_id
      )

      log_debug("Added to buffer: @#{username}/#{post_id}")
    end

    # Update buffer s Mastodon ID (volat po úspěšné publikaci)
    #
    # @param source_id [String] Source/bot identifier
    # @param post_id [String] Twitter status ID
    # @param mastodon_id [String] Mastodon status ID
    def update_buffer_mastodon_id(source_id, post_id, mastodon_id)
      state_manager.update_edit_buffer_mastodon_id(source_id, post_id, mastodon_id)
      log_debug("Updated buffer mastodon_id: #{post_id} → #{mastodon_id}")
    end

    # Cleanup starých záznamů (volat periodicky)
    #
    # @param retention_hours [Integer] Retence v hodinách (default 2)
    # @return [Integer] Počet smazaných záznamů
    def cleanup(retention_hours: 2)
      count = state_manager.cleanup_edit_buffer(retention_hours: retention_hours)
      log_debug("Cleaned up #{count} old buffer entries") if count > 0
      count
    end

    private

    # Najít podobný post v bufferu
    #
    # @param username [String] Normalized username
    # @param normalized_text [String] Normalized text
    # @param text_hash [String] SHA-256 hash
    # @return [Hash, nil] { post_id:, mastodon_id:, similarity: } nebo nil
    def find_similar_in_buffer(username, normalized_text, text_hash)
      # 1. Rychlý hash lookup (exact match)
      exact = state_manager.find_by_text_hash(username, text_hash)
      if exact
        return {
          post_id: exact[:post_id],
          mastodon_id: exact[:mastodon_id],
          similarity: 1.0
        }
      end

      # 2. Pomalý similarity search
      recent = state_manager.find_recent_buffer_entries(username, within_seconds: EDIT_WINDOW)
      return nil if recent.empty?

      best_match = nil
      best_similarity = 0.0

      recent.each do |entry|
        similarity = calculate_similarity(normalized_text, entry[:text_normalized])

        if similarity >= SIMILARITY_THRESHOLD && similarity > best_similarity
          best_similarity = similarity
          best_match = {
            post_id: entry[:post_id],
            mastodon_id: entry[:mastodon_id],
            similarity: similarity
          }
        end
      end

      best_match
    end

    # Vypočítat podobnost mezi dvěma texty
    #
    # @param text1 [String] Normalized text 1
    # @param text2 [String] Normalized text 2
    # @return [Float] Similarity score 0.0-1.0
    def calculate_similarity(text1, text2)
      return 1.0 if text1 == text2
      return 0.0 if text1.empty? || text2.empty?

      # Kombinace metrik pro různé typy editů
      jaccard = jaccard_similarity(text1, text2)
      containment = containment_similarity(text1, text2)
      prefix = prefix_similarity(text1, text2)

      # Pro edity je containment nejlepší metrika
      # (original slova jsou většinou zachována, přidávají se nová)
      # Bereme maximum z jaccard a containment, pak kombinujeme s prefix
      word_similarity = [jaccard, containment].max
      
      (word_similarity * 0.85 + prefix * 0.15)
    end

    # Jaccard similarity (word overlap)
    def jaccard_similarity(text1, text2)
      words1 = text1.split(/\s+/).reject { |w| w.length < 2 }.to_set
      words2 = text2.split(/\s+/).reject { |w| w.length < 2 }.to_set

      return 0.0 if words1.empty? || words2.empty?

      intersection = (words1 & words2).size
      union = (words1 | words2).size

      return 0.0 if union.zero?

      intersection.to_f / union
    end

    # Containment similarity (kolik % kratšího textu je v delším)
    # Lepší pro edity - original slova jsou většinou zachována
    def containment_similarity(text1, text2)
      words1 = text1.split(/\s+/).reject { |w| w.length < 2 }.to_set
      words2 = text2.split(/\s+/).reject { |w| w.length < 2 }.to_set

      return 0.0 if words1.empty? || words2.empty?

      intersection = (words1 & words2).size
      smaller_size = [words1.size, words2.size].min

      return 0.0 if smaller_size.zero?

      intersection.to_f / smaller_size
    end

    # Prefix similarity (pro detekci zkrácených verzí)
    def prefix_similarity(text1, text2)
      shorter, longer = [text1, text2].sort_by(&:length)

      return 0.0 if shorter.empty?

      # Kolik procent kratšího textu je prefixem delšího
      match_length = 0
      shorter.chars.each_with_index do |char, i|
        break unless longer[i] == char
        match_length += 1
      end

      match_length.to_f / shorter.length
    end

    # Normalizovat text pro porovnání
    def normalize_for_comparison(text)
      return '' if text.nil? || text.empty?

      # Text is already URL-decoded by WebhookPayloadParser#parse
      normalized = text.downcase

      # Odstranit URL (můžou se lišit - t.co linky)
      normalized.gsub!(%r{https?://\S+}, '')

      # Odstranit mentions (case může být jiný)
      normalized.gsub!(/@\w+/, '')

      # Odstranit hashtags (můžou být přidány/odebrány)
      normalized.gsub!(/#\w+/, '')

      # Odstranit ellipsis a interpunkci na konci
      normalized.gsub!(/[…\.]{2,}$/, '')
      normalized.gsub!(/[.!?,;:]+$/, '')

      # Normalizovat whitespace
      normalized.gsub!(/\s+/, ' ')

      normalized.strip
    end

    # Normalizovat username
    def normalize_username(username)
      username.to_s.gsub(/^@/, '').downcase
    end

    # Compute SHA-256 hash
    def compute_hash(text)
      Digest::SHA256.hexdigest(text)
    end

    # Porovnat post IDs
    # Twitter Snowflake = pouze číslice → numerické porovnání
    # Bluesky TID = base32 string → lexikografické porovnání (je sortable)
    def compare_post_ids(id1, id2)
      if id1.to_s.match?(/^\d+$/) && id2.to_s.match?(/^\d+$/)
        id1.to_i <=> id2.to_i
      else
        id1.to_s <=> id2.to_s
      end
    end

    # Označit post jako superseded (přeskočený kvůli novější verzi)
    def mark_superseded(source_id, post_id)
      state_manager.mark_edit_superseded(source_id, post_id)
    rescue StandardError => e
      log_warn("Failed to mark superseded: #{e.message}")
    end

    # Logging helpers
    def log_debug(msg)
      @logger&.debug("[EditDetector] #{msg}")
    end

    def log_info(msg)
      @logger&.info("[EditDetector] #{msg}")
    end

    def log_warn(msg)
      @logger&.warn("[EditDetector] #{msg}")
    end
  end
end
