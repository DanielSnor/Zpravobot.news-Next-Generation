
# frozen_string_literal: true

# Media model for Zpravobot NG
# Represents media attachments (images, videos, link cards) in posts

class Media
  VALID_TYPES = %w[image video gif audio link_card video_thumbnail].freeze

  attr_reader :type, :url, :alt_text, :width, :height, :thumbnail_url, :title, :description

  def initialize(type:, url:, alt_text: nil, width: nil, height: nil, thumbnail_url: nil, title: nil, description: nil)
    @type = validate_type(type)
    @url = url
    @alt_text = alt_text || ''
    @width = width
    @height = height
    @thumbnail_url = thumbnail_url
    @title = title
    @description = description
end

  # Type checks
  def image?
    type == 'image'
  end

  def video?
    type == 'video' || type == 'video_thumbnail'
  end

  def gif?
    type == 'gif'
  end

  def audio?
    type == 'audio'
  end

  def link_card?
    type == 'link_card'
  end

  # Check if this is visual media (can be displayed)
  def visual?
    image? || video? || gif?
  end

  # Serialization
  def to_h
  {
    type: type,
    url: url,
    alt_text: alt_text,
    width: width,
    height: height,
    thumbnail_url: thumbnail_url,
    title: title,
    description: description
  }.compact
end

  def inspect
    "#<Media type=#{type} url=#{url[0..50]}...>"
  end

  def ==(other)
    return false unless other.is_a?(Media)
    url == other.url
  end

  alias eql? ==

  def hash
    url.hash
  end

  private

  def validate_type(type)
    type_str = type.to_s.downcase
    unless VALID_TYPES.include?(type_str)
      raise ArgumentError, "Invalid media type: #{type}. Valid types: #{VALID_TYPES.join(', ')}"
    end
    type_str
  end
end

