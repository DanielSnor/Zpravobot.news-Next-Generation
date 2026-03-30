# frozen_string_literal: true

module Stats
  # Formats the weekly ZpravobotStats hitparáda post for publication on Mastodon.
  #
  # Každý týden jeden post na jazykovou skupinu (CZ, SK).
  # Žádná rotace — vše každý týden.
  #
  # Struktura:
  #   1. Hlavička   — týden, datum, jazyk
  #   2. Skokan aktivity  — největší nárůst postů (pokud existuje)
  #   3. Skokan followers — největší nárůst sledujících (pokud existuje)
  #   4. 🏆 Nejaktivnější boty — TOP N podle počtu postů za týden
  #   5. 👥 Nejsledovanější boty — TOP N podle followers
  #   6. 🏷️ TOP kategorie — podle postů za týden
  #   7. Pata — zpravobot.news + hashtag
  #
  # Limit: 2500 znaků (zpravobot.news instance).
  # Auto-truncate: TOP 10 → TOP 5 → TOP 3 pokud post přesahuje limit.
  #
  # Input data hash:
  #   :lang              String   'cz' nebo 'sk'
  #   :week_number       Integer  ISO číslo týdne
  #   :date_from         Date
  #   :date_to           Date
  #   :posts_per_account Hash     { account_id => { this_week:, last_week: } }
  #   :mastodon_stats    Hash     { account_id => { followers:, display_name: } }
  #   :category_stats    Array    [{ category:, posts:, accounts: }, ...]
  #   :skokan            Hash     { activity: Hash|nil, followers: Hash|nil }
  #
  class StatsPostFormatter
    MAX_LENGTH  = 2500
    TOP_N_STEPS = [10, 5, 3].freeze

    LANG_LABELS = {
      'cs' => '🇨🇿 CZ',
      'cz' => '🇨🇿 CZ',  # alias pro případ překlep
      'sk' => '🇸🇰 SK'
    }.freeze

    # Format the weekly hitparáda post.
    # @param data [Hash] stats data (see class docs for keys)
    # @return [String] formatted post (max 2500 chars)
    # @raise [RuntimeError] if even the shortest version exceeds MAX_LENGTH
    def format(data)
      TOP_N_STEPS.each do |top_n|
        post = assemble(data, top_n: top_n)
        return post if post.length <= MAX_LENGTH
      end

      raise "Post příliš dlouhý i po zkrácení na TOP 3 (#{assemble(data, top_n: 3).length} znaků)"
    end

    private

    def assemble(data, top_n:)
      parts = []
      parts << header(data)
      parts << top_followers_section(data[:mastodon_stats], top_n)
      parts << top_accounts_section(data[:posts_per_account], top_n)
      parts << skokani_section(data[:skokan])
      parts << top_categories_section(data[:category_stats], top_n)
      parts << footer
      parts.reject(&:empty?).join("\n\n")
    end

    # ================================================================
    # Hlavička
    # ================================================================

    def header(data)
      lang  = LANG_LABELS.fetch(data[:lang].to_s, data[:lang].to_s.upcase)
      week  = data[:week_number]
      from  = data[:date_from].strftime('%-d. %-m.')
      to    = data[:date_to].strftime('%-d. %-m. %Y')
      "📊 #ZpravobotTOP10 #{lang} — týden #{week} (#{from} – #{to})"
    end

    # ================================================================
    # Skokan sekce — oba typy každý týden
    # ================================================================

    def skokani_section(skokan)
      return "" unless skokan

      lines = []
      if skokan[:activity]
        s = skokan[:activity]
        lines << "🦘 Skokan aktivity: @#{s[:account]} — #{s[:description]}"
      end
      if skokan[:followers]
        s = skokan[:followers]
        lines << "📈 Skokan followers: @#{s[:account]} — #{s[:description]}"
      end
      lines.empty? ? "" : lines.join("\n")
    end

    # ================================================================
    # TOP N nejaktivnějších botů
    # ================================================================

    def top_accounts_section(posts_per_account, top_n)
      sorted = posts_per_account
        .select { |_, v| v[:this_week].to_i > 0 }
        .sort_by { |_, v| -v[:this_week].to_i }
        .first(top_n)
      return "" if sorted.empty?

      lines = ["🏆 Nejaktivnější boty (TOP #{[sorted.size, top_n].min}):"]
      sorted.each_with_index do |(account, data), i|
        curr  = data[:this_week].to_i
        prev  = data[:last_week].to_i
        trend = trend_str(curr, prev)
        lines << "#{medal(i)} @#{account} — #{curr} postů#{trend}"
      end
      lines.join("\n")
    end

    # ================================================================
    # TOP N nejsledovanějších botů
    # ================================================================

    def top_followers_section(mastodon_stats, top_n)
      sorted = mastodon_stats
        .select { |_, v| (v[:followers] || 0) > 0 }
        .sort_by { |_, v| -(v[:followers] || 0) }
        .first(top_n)
      return "" if sorted.empty?

      lines = ["👥 Nejsledovanější boty (TOP #{[sorted.size, top_n].min}):"]
      sorted.each_with_index do |(account, data), i|
        followers = data[:followers].to_i
        lines << "#{medal(i)} @#{account} — #{followers} sledujících"
      end
      lines.join("\n")
    end

    # ================================================================
    # TOP N kategorií
    # ================================================================

    def top_categories_section(category_stats, top_n)
      top = (category_stats || []).first(top_n)
      return "" if top.empty?

      lines = ["🏷️ TOP kategorie (TOP #{top.size}):"]
      top.each_with_index do |row, i|
        lines << "#{medal(i)} #{row[:category]} — #{row[:posts]} postů (#{row[:accounts]} botů)"
      end
      lines.join("\n")
    end

    # ================================================================
    # Pata
    # ================================================================

    def footer
      "🌐 zpravobot.news"
    end

    # ================================================================
    # Helpers
    # ================================================================

    def trend_str(current, previous)
      return "" if previous.nil? || previous.to_i.zero?

      diff = current.to_i - previous.to_i
      pct  = (diff.to_f / previous.to_i * 100).round

      if diff > 0
        " (+#{pct}% ↑)"
      elsif diff < 0
        " (#{pct}% ↓)"
      else
        " (→)"
      end
    end

    def medal(index)
      case index
      when 0 then "🥇"
      when 1 then "🥈"
      when 2 then "🥉"
      else        "#{index + 1}."
      end
    end
  end
end
