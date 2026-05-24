# frozen_string_literal: true

# ============================================================
# MastodonProfileUpdater — Mastodon profile update API client
# ============================================================
#
# Wraps the two Mastodon API calls needed for profile sync:
#   - GET  /api/v1/accounts/verify_credentials  → fetch current fields
#   - PATCH /api/v1/accounts/update_credentials → write bio/fields/avatar/header
#
# Used by BaseProfileSyncer. Decoupled from publish flow (MastodonPublisher).
#
# Usage:
#   updater = Syncers::MastodonProfileUpdater.new(
#     instance_url: 'https://zpravobot.news',
#     access_token: 'xxx'
#   )
#   fields = updater.fetch_fields
#   result = updater.update(params, files)
#   # => { success: true, account: {...} }
#
# ============================================================

require 'net/http'
require 'uri'
require 'json'
require_relative '../utils/http_client'
require_relative '../utils/html_cleaner'

module Syncers
  class MastodonProfileUpdater
    def initialize(instance_url:, access_token:)
      @instance_url = instance_url.chomp('/')
      @access_token = access_token
    end

    # Fetch current profile fields from Mastodon.
    # @return [Array<Hash>] Array of { name:, value: } with HTML stripped from values
    # @raise [RuntimeError] if the API request fails
    def fetch_fields
      url = "#{@instance_url}/api/v1/accounts/verify_credentials"
      response = HttpClient.get(url, headers: auth_headers)

      unless response.is_a?(Net::HTTPSuccess)
        raise "Failed to fetch Mastodon profile: #{response.code}"
      end

      data = JSON.parse(response.body)
      fields = data['fields'] || []
      fields.map { |f| { name: f['name'], value: HtmlCleaner.sanitize_html(f['value']) } }
    end

    # Update Mastodon profile credentials.
    # @param params [Hash] Text fields (note, fields_attributes, etc.)
    # @param files [Hash] Binary files — keys :avatar or :header, values { data:, content_type:, filename: }
    # @return [Hash] { success: true, account: {...} } or { success: false, error: '...' }
    def update(params, files)
      uri = URI("#{@instance_url}/api/v1/accounts/update_credentials")

      request = if files.any?
        boundary = "----ZpravobotBoundary#{rand(1_000_000_000)}"
        req = Net::HTTP::Patch.new(uri)
        req['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
        req.body = build_multipart_body(params, files, boundary)
        req
      else
        req = Net::HTTP::Patch.new(uri)
        req['Content-Type'] = 'application/x-www-form-urlencoded'
        req.body = URI.encode_www_form(params)
        req
      end

      request['Authorization'] = "Bearer #{@access_token}"
      request['User-Agent'] = HttpClient::DEFAULT_UA

      response = HttpClient.patch_raw(uri, request)

      if response.is_a?(Net::HTTPSuccess)
        { success: true, account: JSON.parse(response.body) }
      else
        error = begin
          JSON.parse(response.body)['error']
        rescue StandardError
          response.body
        end
        { success: false, error: error }
      end
    end

    private

    def auth_headers
      { 'Authorization' => "Bearer #{@access_token}" }
    end

    def build_multipart_body(params, files, boundary)
      body = ''.b

      params.each do |key, value|
        body << "--#{boundary}\r\n".b
        body << "Content-Disposition: form-data; name=\"#{key}\"\r\n\r\n".b
        body << value.to_s.dup.force_encoding('UTF-8').b
        body << "\r\n".b
      end

      files.each do |key, file_data|
        safe_filename = sanitize_multipart_filename(file_data[:filename])
        body << "--#{boundary}\r\n".b
        body << "Content-Disposition: form-data; name=\"#{key}\"; filename=\"#{safe_filename}\"\r\n".b
        body << "Content-Type: #{file_data[:content_type]}\r\n\r\n".b
        body << file_data[:data].b
        body << "\r\n".b
      end

      body << "--#{boundary}--\r\n".b
      body
    end

    # Sanitizace filename pro Content-Disposition header — viz stejný komentář
    # v Publishers::MastodonPublisher#sanitize_multipart_filename. ImageCacheManager
    # už filenames generuje bezpečně ('profile.jpg' apod.), takže tento sanitizér
    # je defense-in-depth pro budoucí callsity.
    def sanitize_multipart_filename(filename)
      cleaned = filename.to_s.gsub(/[^a-zA-Z0-9._-]/, '_')
      cleaned = 'media' if cleaned.empty?
      cleaned[0, 200]
    end
  end
end
