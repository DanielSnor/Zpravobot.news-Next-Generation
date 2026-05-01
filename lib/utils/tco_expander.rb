# frozen_string_literal: true

require 'net/http'
require_relative 'http_client'
require_relative 'punycode'

module Utils
  # Expanduje t.co zkrácené URL na jejich cílové adresy přes HTTP HEAD redirect.
  # Tichá selhání: nedostupný/neresolvovatelný t.co se vrací beze změny.
  module TcoExpander
    # Path charset je [A-Za-z0-9] — \S+ by spolkl trailing emoji/interpunkci,
    # kterou někteří zdroje (IFTTT) emitují bez oddělovače za URL.
    TCO_PATTERN = %r{https?://t\.co/[A-Za-z0-9]+}

    # Expanduje všechny t.co linky v textu
    # @param text [String, nil]
    # @return [String, nil] text s expandovanými t.co linky (nebo nil pokud vstup nil)
    def self.expand(text)
      return text unless text
      text.gsub(TCO_PATTERN) { |url| expand_one(url) || url }
    end

    # Expanduje jedno t.co URL
    # @param tco_url [String]
    # @return [String, nil] cílová URL nebo nil pokud nelze resolvnout
    def self.expand_one(tco_url)
      return nil unless tco_url&.match?(%r{https?://t\.co/})

      # Strip trailing ellipsis (unicode … nebo ascii ...) — IFTTT někdy přidává
      tco_url = tco_url.gsub(/[…\.]{1,3}\z/, '')
      return nil unless tco_url.match?(%r{https?://t\.co/\w})

      response = HttpClient.head(tco_url, open_timeout: 3, read_timeout: 3)
      case response
      when Net::HTTPRedirection
        PunycodeDecoder.decode_url(response['location'])
      end
    rescue StandardError
      nil
    end
  end
end
