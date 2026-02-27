
# frozen_string_literal: true

# Author model for Zpravobot NG
# Represents the author of a post across all platforms

class Author
  attr_reader :username, :display_name, :full_name, :url, :avatar_url

  def initialize(username:, display_name: nil, full_name: nil, url: nil, avatar_url: nil)
    @username = username.to_s.gsub(/^@/, '')  # Remove @ if present
    @display_name = display_name || full_name || @username
    @full_name = full_name || display_name || @username
    @url = url
    @avatar_url = avatar_url
  end

  # Display name with fallback to username
  def name
    display_name || username
  end

  # Username with @ prefix
  def handle
    "@#{username}"
  end

  # Serialization
  def to_h
    {
      username: username,
      display_name: display_name,
      full_name: full_name,
      url: url,
      avatar_url: avatar_url
    }.compact
  end

  def inspect
    "#<Author @#{username} (#{display_name})>"
  end

  def ==(other)
    return false unless other.is_a?(Author)
    username.downcase == other.username.downcase
  end

  alias eql? ==

  def hash
    username.downcase.hash
  end
end

