# frozen_string_literal: true

class SourceGenerator
  PLATFORMS = %w[twitter bluesky rss youtube].freeze
  PRIORITIES = %w[high normal low].freeze
  VISIBILITIES = %w[public unlisted private].freeze
  LANGUAGES = %w[cs sk en].freeze
  RETENTION_OPTIONS = [7, 30, 90, 180].freeze
  DEFAULT_INSTANCE = 'https://zpravobot.news'

  # Content mode options for RSS/YouTube
  CONTENT_MODES = {
    'text' => { show_title_as_content: false, combine_title_and_content: false },
    'title' => { show_title_as_content: true, combine_title_and_content: false },
    'combined' => { show_title_as_content: false, combine_title_and_content: true }
  }.freeze

  # RSS source types (for RSS.app feeds from social networks)
  RSS_SOURCE_TYPES = {
    'rss' => { label: 'RSS', suffix: 'rss' },
    'facebook' => { label: 'Facebook', suffix: 'facebook' },
    'instagram' => { label: 'Instagram', suffix: 'instagram' },
    'other' => { label: nil, suffix: nil }  # Custom - user provides
  }.freeze

  # Bluesky source types (profile vs custom feed)
  BLUESKY_SOURCE_TYPES = {
    'handle' => { label: 'Profil (handle)', suffix: 'bluesky' },
    'feed' => { label: 'Custom feed', suffix: 'bluesky_feed' }
  }.freeze

  # Content replacements for RSS.app FB/IG feeds (clean up noise)
  RSSAPP_CONTENT_REPLACEMENTS = [
    { pattern: "^.+?\\s+(Posted|shared|updated status)$", replacement: "", flags: "i", literal: false },
    { pattern: "(When[^>]+deleted.)", replacement: "", flags: "gim", literal: false }
  ].freeze

  # Banned phrases for Facebook/Instagram sources (filter out noise posts)
  RSSAPP_BANNED_PHRASES = {
    'facebook' => [
      "updated their cover photo",
      "updated their profile picture",
      "is with",
      "was live"
    ],
    'instagram' => [
      "updated their profile picture"
    ]
  }.freeze

  # URL domain choices for Twitter sources on non-zpravobot instances
  TWITTER_URL_DOMAINS = %w[twitter.com x.com nitter.net xcancel.com].freeze

  # Bluesky source type UI options
  BLUESKY_SOURCE_TYPE_OPTIONS = ['Profil (handle)', 'Custom feed'].freeze
  BLUESKY_SOURCE_TYPE_MAP = { 'Profil (handle)' => 'handle', 'Custom feed' => 'feed' }.freeze

  # RSS source type UI options
  RSS_SOURCE_TYPE_OPTIONS = ['RSS', 'Facebook (via RSS.app)', 'Instagram (via RSS.app)', 'Jiný (vlastní název)'].freeze
  RSS_SOURCE_TYPE_MAP = {
    'RSS' => 'rss', 'Facebook (via RSS.app)' => 'facebook',
    'Instagram (via RSS.app)' => 'instagram', 'Jiný (vlastní název)' => 'other'
  }.freeze

  # Twitter URL domain UI options
  TWITTER_URL_DOMAIN_OPTIONS = [
    'twitter.com - originální Twitter',
    'x.com - originální Twitter (nová doména)',
    'nitter.net - Nitter instance',
    'xcancel.com - další Nitter instance'
  ].freeze

  # Content mode UI options
  CONTENT_MODE_OPTIONS = [
    'Text - použít popis/obsah',
    'Titulek místo textu - použít pouze titulek',
    'Kombinovat titulek a text - titulek + oddělovač + popis'
  ].freeze
  CONTENT_MODE_MAP = {
    'Text - použít popis/obsah' => 'text',
    'Titulek místo textu - použít pouze titulek' => 'title',
    'Kombinovat titulek a text - titulek + oddělovač + popis' => 'combined'
  }.freeze
end
