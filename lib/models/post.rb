# frozen_string_literal: true

require_relative 'author'
require_relative 'media'

# Unified representation of a post across different platforms (RSS, Twitter, Bluesky, YouTube)
# Extended with thread support for Twitter self-replies
#
# Thread support:
#   is_thread_post  - true if this is a self-reply (part of a thread)
#   thread_context  - fetched context with before/after tweets (lazy loaded)
#   reply_to_handle - handle being replied to (for thread detection)
#
# Video support:
#   has_video       - true if post contains video content
#
class Post
  attr_reader :platform, :id, :url, :title, :published_at,
              :is_reply,
              :reply_to, :media,
              :is_thread_post, :reply_to_handle

  # Author is mutable (Tier 2 repost fallback may correct Nitter's author)
  attr_accessor :author

  # Mutable attributes (set after construction by adapters/processors)
  attr_accessor :text, :has_video, :is_quote, :quoted_post, :is_repost, :reposted_by, :raw
  
  # Thread context is mutable (can be loaded lazily)
  attr_accessor :thread_context

  def initialize(
    platform:,
    id:,
    url:,
    text:,
    published_at:,
    author:,
    title: nil,
    is_repost: false,
    is_quote: false,
    is_reply: false,
    reposted_by: nil,
    quoted_post: nil,
    reply_to: nil,
    media: [],
    raw: nil,
    # Thread support
    is_thread_post: false,
    reply_to_handle: nil,
    thread_context: nil,
    # Video support
    has_video: false
  )
    @platform = platform.to_s.downcase
    @id = id
    @url = url
    @title = title
    @text = text
    @published_at = published_at
    @author = author
    @is_repost = is_repost
    @is_quote = is_quote
    @is_reply = is_reply
    @reposted_by = reposted_by
    @quoted_post = quoted_post
    @reply_to = reply_to
    @media = media || []
    @raw = raw
    # Thread support
    @is_thread_post = is_thread_post
    @reply_to_handle = reply_to_handle
    @thread_context = thread_context
    # Video support
    @has_video = has_video
  end

  # Platform checks
  def rss?
    platform == 'rss'
  end

  def bluesky?
    platform == 'bluesky'
  end

  def twitter?
    platform == 'twitter'
  end

  def youtube?
    platform == 'youtube'
  end

  # Social platforms (Twitter, Bluesky) vs content platforms (RSS, YouTube)
  def social?
    twitter? || bluesky?
  end

  def content?
    rss? || youtube?
  end

  # Content checks
  def has_media?
    !media.empty?
  end

  def has_video?
    @has_video == true
  end

  def has_title?
    title && !title.strip.empty?
  end

  def has_text?
    text && !text.strip.empty?
  end

  def empty?
    !has_text? && !has_title? && !has_media?
  end

  # Author helpers
  def author_name
    author.display_name
  end

  def author_username
    author.username
  end

  # Repost/Quote helpers
  def self_repost?
    is_repost && reposted_by && author.username == reposted_by
  end

  def self_quote?
    is_quote && quoted_post && 
      quoted_post[:author] && 
      author.username == quoted_post[:author]
  end

  def external_repost?
    is_repost && !self_repost?
  end

  # ============================================
  # Thread helpers
  # ============================================

  # Check if this is a self-reply (thread continuation)
  # A self-reply is when the user replies to their own tweet
  def self_reply?
    is_reply && reply_to_handle && 
      author.username.to_s.downcase == reply_to_handle.to_s.downcase
  end

  # Alias for clarity
  alias thread_post? is_thread_post

  # Check if this is an external reply (to someone else)
  def external_reply?
    is_reply && !self_reply?
  end

  # Check if thread context has been loaded
  def thread_context_loaded?
    !thread_context.nil?
  end

  # Get thread position (1-based, where 1 = first tweet in thread)
  def thread_position
    thread_context&.dig(:position) || 1
  end

  # Get total tweets in thread
  def thread_total
    thread_context&.dig(:total) || 1
  end

  # Check if this is the first tweet in a thread
  def thread_start?
    !is_thread_post || thread_context&.dig(:is_thread_start) == true
  end

  # Check if this is the last tweet in a thread
  def thread_end?
    thread_context&.dig(:is_thread_end) == true
  end

  # Get tweets that came before this one in the thread
  def thread_before
    thread_context&.dig(:before) || []
  end

  # Get tweets that came after this one in the thread (from same author)
  def thread_after
    thread_context&.dig(:after) || []
  end

  # Get thread indicator for display (e.g., "2/5" or "🧵 2/5")
  # @param emoji [Boolean] Include thread emoji
  # @return [String, nil] Thread indicator or nil if not a thread
  def thread_indicator(emoji: true)
    return nil unless is_thread_post && thread_context_loaded?
    
    indicator = "#{thread_position}/#{thread_total}"
    emoji ? "🧵 #{indicator}" : indicator
  end

  # ============================================
  # Serialization
  # ============================================
  
  def to_h
    {
      platform: platform,
      id: id,
      url: url,
      title: title,
      text: text,
      published_at: published_at,
      author: author.to_h,
      is_repost: is_repost,
      is_quote: is_quote,
      is_reply: is_reply,
      reposted_by: reposted_by,
      quoted_post: quoted_post,
      reply_to: reply_to,
      media: media.map(&:to_h),
      has_media: has_media?,
      has_title: has_title?,
      has_video: has_video?,
      # Thread fields
      is_thread_post: is_thread_post,
      reply_to_handle: reply_to_handle,
      thread_context: thread_context
    }.compact
  end

  def inspect
    thread_info = is_thread_post ? " thread=#{thread_indicator(emoji: false) || 'yes'}" : ""
    video_info = has_video? ? " video=yes" : ""
    "#<Post platform=#{platform} id=#{id} author=#{author_username} " \
    "repost=#{is_repost} quote=#{is_quote} reply=#{is_reply}#{thread_info}#{video_info}>"
  end
end
