# frozen_string_literal: true

require_relative 'social_text_heuristics'

module Processors
  # Threads Content Processor — viz Processors::SocialTextHeuristics.
  # restore_long_paragraph_breaks se uplatní méně (Threads limit 500 znaků).
  class ThreadsProcessor
    include SocialTextHeuristics

    def initialize(config = {})
      @config = config
    end

    def process(text)
      return '' if text.nil? || text.empty?

      result = text.dup
      result = decode_rss_app_artifacts(result)
      result = restore_paragraph_breaks(result)
      result = restore_exclamation_title(result)
      result = restore_flag_list(result)
      result = restore_list_breaks(result)
      result = restore_quote_breaks(result)
      result = restore_long_paragraph_breaks(result)
      result = restore_hashtag_block(result)
      result = cleanup_whitespace(result)
      result.strip
    end
  end
end
