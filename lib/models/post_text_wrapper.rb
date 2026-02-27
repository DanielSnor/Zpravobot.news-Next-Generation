# frozen_string_literal: true

# Simple wrapper to override text on a Post object
# Used by formatters that need to modify post text without mutating the original
class PostTextWrapper
  def initialize(post, new_text)
    @post = post
    @new_text = new_text
  end

  def text
    @new_text
  end

  def method_missing(method, *args, &block)
    @post.send(method, *args, &block)
  end

  def respond_to_missing?(method, include_private = false)
    @post.respond_to?(method, include_private)
  end
end
