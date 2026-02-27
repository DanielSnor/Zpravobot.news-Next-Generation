# frozen_string_literal: true

module Config
  # Finds sources by various criteria (handle, platform, account)
  #
  # Operates on the cached/loaded sources from ConfigLoader
  class SourceFinder
    # Find sources by platform
    # @param all_sources [Array<Hash>] All loaded sources
    # @param platform [String] Platform name
    # @return [Array<Hash>]
    #
    # NOTE: Facebook a Instagram sources mají technicky platform: rss (čtou RSS feed),
    # ale jsou separátní platformy identifikovatelné příponou ID (_facebook, _instagram).
    # Při filtrování platform: rss jsou proto vyloučeny — patří pod svůj vlastní platform.
    RSS_SUBPLATFORM_SUFFIXES = %w[_facebook _instagram].freeze

    def by_platform(all_sources, platform)
      all_sources.select do |s|
        case platform
        when 'rss'
          s[:platform] == 'rss' &&
            RSS_SUBPLATFORM_SUFFIXES.none? { |suffix| s[:id].to_s.end_with?(suffix) }
        when 'facebook'
          s[:platform] == 'rss' && s[:id].to_s.end_with?('_facebook')
        when 'instagram'
          s[:platform] == 'rss' && s[:id].to_s.end_with?('_instagram')
        else
          s[:platform] == platform
        end
      end
    end

    # Find sources by Mastodon account
    # @param all_sources [Array<Hash>] All loaded sources
    # @param account_id [String] Mastodon account identifier
    # @return [Array<Hash>]
    def by_mastodon_account(all_sources, account_id)
      all_sources.select { |s| s.dig(:target, :mastodon_account) == account_id }
    end

    # Find a single source by handle
    # @param all_sources [Array<Hash>] All loaded sources
    # @param platform [String] Platform name
    # @param handle [String] Source handle (case-insensitive)
    # @return [Hash, nil] Source config or nil
    def by_handle(all_sources, platform, handle)
      normalized = handle.downcase
      all_sources.find do |s|
        s[:platform] == platform &&
          s.dig(:source, :handle)&.downcase == normalized
      end
    end
  end
end
