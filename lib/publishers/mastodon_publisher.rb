# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require_relative '../utils/http_client'
require_relative '../utils/mime_detector'
require_relative '../errors'
require_relative '../support/loggable'

module Publishers
  # Mastodon Publisher for ZBNW-NG
  #
  # Handles publishing, updating, and deleting statuses to Mastodon instances.
  # Supports media uploads, threading (replies), and edit detection.
  #
  # Uses shared HttpClient for all HTTP operations with automatic retry
  # for rate limits (429) and server errors (5xx).
  #
  class MastodonPublisher
    include Support::Loggable

    MAX_STATUS_LENGTH = 2500
    MAX_DESCRIPTION_LENGTH = 1500  # Mastodon API limit for media alt text
    MAX_MEDIA_SIZE = 10 * 1024 * 1024  # 10MB
    MAX_MEDIA_COUNT = 4

    # Retry configuration
    MAX_RETRIES_RATE_LIMIT = 3
    MAX_RETRIES_SERVER_ERROR = 2

    attr_reader :instance_url, :access_token

    def initialize(instance_url:, access_token:)
      @instance_url = instance_url.chomp('/')
      @access_token = access_token
      @rate_limited_until = nil
      validate_credentials!
    end

    # Is this account currently rate-limited?
    def rate_limited?
      @rate_limited_until && Time.now < @rate_limited_until
    end

    # Seconds remaining on rate limit (0 if not limited)
    def rate_limit_remaining
      return 0 unless rate_limited?
      (@rate_limited_until - Time.now).ceil
    end

    # Publish a status to Mastodon
    # @param text [String] Status text
    # @param media_ids [Array<String>] Optional media IDs from upload_media
    # @param visibility [String] public, unlisted, private, or direct
    # @param in_reply_to_id [String, nil] Mastodon status ID to reply to (for threading)
    # @return [Hash] Response with 'url' and 'id' of created status
    def publish(text, media_ids: [], visibility: 'public', in_reply_to_id: nil)
      raise_if_rate_limited!

      if (text.nil? || text.strip.empty?) && media_ids.empty?
        raise ArgumentError, "Text cannot be empty without media"
      end
      raise ArgumentError, "Text too long (#{text.length}/#{MAX_STATUS_LENGTH})" if text && text.length > MAX_STATUS_LENGTH

      reply_info = in_reply_to_id ? " [reply to #{in_reply_to_id}]" : ""
      text_len = text&.strip&.length || 0
      log "Publishing status (#{text_len} chars, #{media_ids.size} media#{reply_info})..."

      params = { visibility: visibility }
      params[:status] = text unless text.nil? || text.strip.empty?
      params[:media_ids] = media_ids unless media_ids.empty?
      params[:in_reply_to_id] = in_reply_to_id if in_reply_to_id

      response = api_post('/api/v1/statuses', params)
      code = response.code.to_i

      if code == 429
        mark_rate_limited!(response)
      elsif (200..299).include?(code)
        data = JSON.parse(response.body)
        log "Published: #{data['url']}", level: :success
        data
      else
        error = parse_error(response)
        log "Failed: #{error}", level: :error
        raise Zpravobot::PublishError, "Mastodon API error: #{error}"
      end
    end

    # Update existing Mastodon status (edit)
    #
    # @param status_id [String] Mastodon status ID to update
    # @param text [String] New status text
    # @param media_ids [Array<String>] Optional new media IDs
    # @param sensitive [Boolean] Mark as sensitive
    # @param spoiler_text [String] Content warning text
    # @return [Hash] Updated status data
    def update_status(status_id, text, media_ids: nil, sensitive: nil, spoiler_text: nil)
      raise_if_rate_limited!
      raise ArgumentError, "Status ID required" if status_id.nil? || status_id.to_s.empty?
      raise ArgumentError, "Text cannot be empty" if text.nil? || text.strip.empty?
      raise ArgumentError, "Text too long (#{text.length}/#{MAX_STATUS_LENGTH})" if text.length > MAX_STATUS_LENGTH

      log "Updating status #{status_id} (#{text.strip.length} chars)..."

      params = { status: text }
      params[:media_ids] = media_ids if media_ids
      params[:sensitive] = sensitive unless sensitive.nil?
      params[:spoiler_text] = spoiler_text if spoiler_text

      response = api_put("/api/v1/statuses/#{status_id}", params)

      case response.code.to_i
      when 200
        data = JSON.parse(response.body)
        log "Updated: #{data['url']}", level: :success
        data
      when 429
        mark_rate_limited!(response)
      when 404
        log "Status not found: #{status_id}", level: :error
        raise Zpravobot::StatusNotFoundError, "Status #{status_id} not found"
      when 403
        log "Cannot edit: not owner or edit window expired", level: :error
        raise Zpravobot::EditNotAllowedError, "Cannot edit status #{status_id}"
      when 422
        error = parse_error(response)
        log "Validation error: #{error}", level: :error
        raise Zpravobot::ValidationError, error
      else
        error = parse_error(response)
        log "Update failed: #{error}", level: :error
        raise Zpravobot::PublishError, "Mastodon API error: #{error}"
      end
    end

    # Delete a Mastodon status
    #
    # @param status_id [String] Mastodon status ID to delete
    # @return [Hash] Empty hash on success
    def delete_status(status_id)
      raise ArgumentError, "Status ID required" if status_id.nil? || status_id.to_s.empty?

      log "Deleting status #{status_id}..."

      response = api_delete("/api/v1/statuses/#{status_id}")

      case response.code.to_i
      when 200, 204
        log "Deleted: #{status_id}", level: :success
        {}
      when 404
        log "Status not found: #{status_id}", level: :error
        raise Zpravobot::StatusNotFoundError, "Status #{status_id} not found"
      when 403
        log "Cannot delete: not owner", level: :error
        raise Zpravobot::EditNotAllowedError, "Cannot delete status #{status_id}"
      else
        error = parse_error(response)
        log "Delete failed: #{error}", level: :error
        raise Zpravobot::PublishError, "Mastodon API error: #{error}"
      end
    end

    # Favourite a Mastodon status
    #
    # @param status_id [String] Mastodon status ID to favourite
    # @return [Hash] Favourited status data
    def favourite_status(status_id)
      raise ArgumentError, "Status ID required" if status_id.nil? || status_id.to_s.empty?

      log "Favouriting status #{status_id}..."

      response = api_post("/api/v1/statuses/#{status_id}/favourite", {})

      case response.code.to_i
      when 200
        data = JSON.parse(response.body)
        log "Favourited: #{status_id}", level: :success
        data
      when 404
        log "Status not found: #{status_id}", level: :error
        raise Zpravobot::StatusNotFoundError, "Status #{status_id} not found"
      else
        error = parse_error(response)
        log "Favourite failed: #{error}", level: :error
        raise Zpravobot::PublishError, "Favourite failed: #{error}"
      end
    end

    # Check if status can be edited
    #
    # @param status_id [String] Mastodon status ID
    # @return [Boolean] true if editable
    def can_edit?(status_id)
      status = get_status(status_id)
      return false unless status

      our_account = verify_credentials
      status['account']['id'] == our_account['id']
    rescue StandardError
      false
    end

    # Get status by ID
    #
    # @param status_id [String] Mastodon status ID
    # @return [Hash, nil] Status data or nil if not found
    def get_status(status_id)
      response = api_get("/api/v1/statuses/#{status_id}")

      if (200..299).include?(response.code.to_i)
        JSON.parse(response.body)
      end
    end

    # Get edit history for a status
    #
    # @param status_id [String] Mastodon status ID
    # @return [Array<Hash>] Array of historical versions
    def get_edit_history(status_id)
      response = api_get("/api/v1/statuses/#{status_id}/history")

      if (200..299).include?(response.code.to_i)
        JSON.parse(response.body)
      else
        []
      end
    end

    # Upload media from URL (downloads then uploads).
    # If url_variants is provided and the primary URL is too large, tries smaller variants in order.
    # @param url [String] URL of image/video to upload
    # @param description [String] Alt text for accessibility
    # @param url_variants [Array<String>] Fallback URLs to try if primary is too large (best-first)
    # @param max_size [Integer] Maximum allowed file size in bytes (default: MAX_MEDIA_SIZE)
    # @return [String, nil] Media ID or nil on failure
    def upload_media_from_url(url, description: nil, url_variants: [], max_size: MAX_MEDIA_SIZE)
      urls_to_try = ([url] + (url_variants || []).reject { |u| u == url }).compact

      urls_to_try.each_with_index do |try_url, idx|
        label = idx == 0 ? "" : " (variant #{idx})"
        try_url = resolve_nitter_proxy_url(try_url)
        try_url = encode_non_ascii_url(try_url)

        ext = File.extname(URI.parse(try_url).path).downcase rescue ''
        if UNSUPPORTED_MEDIA_EXTENSIONS.include?(ext)
          log "Skipping unsupported media type (#{ext}): #{try_url}", level: :warn
          next
        end

        log "Downloading media from: #{try_url}#{label}"

        response = HttpClient.download(
          try_url,
          max_size: max_size,
          on_failure: ->(r) {
            geo = r['x-geo-forbidden'] == 'true' ? ' geo-blocked' : ''
            log "Download failed (#{r.code}#{geo}): #{try_url}", level: :error
          }
        )
        if response == :too_large
          log "Skipping media over #{max_size / 1024 / 1024}MB: #{try_url}", level: :warn
          next
        end
        next unless response

        image_data = response.body
        if image_data.nil? || image_data.empty?
          log "Downloaded empty file from: #{try_url}", level: :error
          next
        end

        log "Downloaded #{image_data.bytesize} bytes"

        content_type = detect_content_type(try_url, image_data)
        if content_type == 'application/octet-stream'
          log "Skipping unrecognized media type for: #{try_url}", level: :warn
          next
        end

        filename = File.basename(URI.parse(try_url).path) rescue 'media'
        filename = 'media' if filename.empty?
        filename = correct_filename_extension(filename, content_type)

        log "Media type detected: #{content_type} for #{filename} (from #{try_url})"

        return upload_media(image_data, filename: filename, content_type: content_type, description: description)
      end

      nil
    end

    # Upload media from a local file path
    # @param path [String] Absolute or relative path to file
    # @param description [String] Alt text for accessibility
    # @return [String, nil] Media ID or nil on failure
    def upload_media_from_file(path, description: nil)
      raise ArgumentError, "File not found: #{path}" unless File.exist?(path)

      data = File.binread(path)
      raise ArgumentError, "File too large (#{data.bytesize} > #{MAX_MEDIA_SIZE})" if data.bytesize > MAX_MEDIA_SIZE
      raise ArgumentError, "File is empty: #{path}" if data.empty?

      content_type = detect_content_type_from_path(path, data)

      if content_type == 'application/octet-stream'
        raise ArgumentError, "Cannot determine media type for: #{path}"
      end

      filename = File.basename(path)
      filename = correct_filename_extension(filename, content_type)

      log "Uploading local file: #{filename} (#{content_type}, #{data.bytesize} bytes)"

      upload_media(data, filename: filename, content_type: content_type, description: description)
    end

    # Upload media binary data to Mastodon
    # @param data [String] Binary image data
    # @param filename [String] Filename with extension
    # @param content_type [String] MIME type
    # @param description [String] Alt text
    # @return [String, nil] Media ID or nil on failure
    def upload_media(data, filename:, content_type:, description: nil)
      raise_if_rate_limited!
      raise ArgumentError, "No data provided" if data.nil? || data.empty?
      raise ArgumentError, "File too large (#{data.bytesize} > #{MAX_MEDIA_SIZE})" if data.bytesize > MAX_MEDIA_SIZE

      if description && description.length >= MAX_DESCRIPTION_LENGTH
        log "Alt text truncated (#{description.length} → #{MAX_DESCRIPTION_LENGTH} chars)", level: :warn
        description = "#{description[0, MAX_DESCRIPTION_LENGTH - 1]}…"
      end

      log "Uploading media: #{filename} (#{content_type}, #{data.bytesize} bytes)"

      uri = URI("#{instance_url}/api/v2/media")

      boundary = "----ZpravobotBoundary#{rand(1_000_000_000)}"
      body = build_multipart_body(boundary, data, filename, content_type, description)

      request = Net::HTTP::Post.new(uri)
      request['Authorization'] = "Bearer #{access_token}"
      request['User-Agent'] = HttpClient::DEFAULT_UA
      request['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
      request.body = body

      response = execute_with_retry(uri, request)

      if (200..299).include?(response.code.to_i)
        result = JSON.parse(response.body)
        media_id = result['id']

        if response.code.to_i == 202
          ready = wait_for_media_processing(media_id)
          unless ready
            raise Zpravobot::NetworkError, "Media #{media_id} not ready after polling timeout — aborting publish"
          end
        end

        log "Media uploaded, ID: #{media_id}", level: :success
        media_id
      else
        error = parse_error(response)
        log "Media upload failed: #{error}", level: :error
        nil
      end
    end

    # Verify credentials are valid
    # @return [Hash] Account info
    def verify_credentials
      log "Verifying credentials..."

      response = api_get('/api/v1/accounts/verify_credentials')

      if (200..299).include?(response.code.to_i)
        data = JSON.parse(response.body)
        log "Authenticated as @#{data['username']}", level: :success
        data
      else
        log "Invalid credentials", level: :error
        raise Zpravobot::ConfigError, "Invalid Mastodon credentials"
      end
    end

    # Upload multiple media files in parallel using threads.
    # Each item that fails is logged and skipped — partial media is returned.
    # Order of returned media_ids matches the input order (nil slots removed).
    #
    # @param media_items [Array<Hash>] each with :url (required) and :description (optional)
    # @param max_size [Integer] Maximum allowed file size in bytes (default: MAX_MEDIA_SIZE)
    # @return [Array<String>] media IDs in original order, failed uploads excluded
    def upload_media_parallel(media_items, max_size: MAX_MEDIA_SIZE)
      return [] if media_items.nil? || media_items.empty?
      raise_if_rate_limited!

      items = media_items.first(MAX_MEDIA_COUNT)
      if media_items.size > MAX_MEDIA_COUNT
        log "Media count #{media_items.size} exceeds limit #{MAX_MEDIA_COUNT}, uploading first #{MAX_MEDIA_COUNT} only", level: :warn
      end

      log "Uploading #{items.size} media files in parallel..."

      threads = items.each_with_index.map do |item, idx|
        Thread.new(item, idx) do |it, i|
          Thread.current[:index] = i
          begin
            upload_media_from_url(it[:url], description: it[:description], url_variants: it[:url_variants], max_size: max_size)
          rescue Zpravobot::AccountRateLimitedError => e
            Thread.current[:rate_limited] = e
            nil
          rescue StandardError => e
            log "Media upload failed (#{i + 1}/#{items.size}): #{e.message}", level: :warn
            nil
          end
        end
      end

      results = threads.map(&:value)

      # If any thread hit a rate limit, re-raise it — the publisher's @rate_limited_until
      # was already set inside upload_media, so subsequent calls will skip via pre-flight.
      rl_thread = threads.find { |t| t[:rate_limited] }
      raise rl_thread[:rate_limited] if rl_thread

      media_ids = results.compact

      log "Parallel upload complete: #{media_ids.size}/#{items.size} succeeded"
      media_ids
    end

    # Upload media from pre-downloaded binary data.
    # Used when binary data has already been fetched (e.g., for video dedup check)
    # to avoid downloading the video a second time.
    #
    # @param data [String] Binary media data (already downloaded)
    # @param url [String] Original URL — used for extension/type detection fallback
    # @param description [String, nil] Alt text for accessibility
    # @param max_size [Integer] Maximum allowed file size in bytes (default: MAX_MEDIA_SIZE)
    # @return [String, nil] Media ID or nil on failure
    def upload_media_from_data(data, url:, description: nil, max_size: MAX_MEDIA_SIZE)
      return nil if data.nil? || data.empty?
      return nil if data.bytesize > max_size

      content_type = detect_content_type(url, data)
      if content_type == 'application/octet-stream'
        log "Skipping unrecognized media type for cached data from: #{url}", level: :warn
        return nil
      end

      filename = File.basename(URI.parse(url).path) rescue 'media'
      filename = 'media' if filename.empty?
      filename = correct_filename_extension(filename, content_type)

      log "Uploading cached media: #{filename} (#{content_type}, #{data.bytesize} bytes)"
      upload_media(data, filename: filename, content_type: content_type, description: description)
    rescue StandardError => e
      log "Cached media upload failed: #{e.message}", level: :error
      nil
    end

    # Backward-compatible error aliases
    StatusNotFoundError = Zpravobot::StatusNotFoundError
    EditNotAllowedError = Zpravobot::EditNotAllowedError
    ValidationError = Zpravobot::ValidationError

    private

    # Rewrite Nitter image proxy URLs to direct Twitter CDN URLs.
    #
    # Nitter's /pic/orig/ proxy appends "?name=orig" unconditionally, even when
    # the decoded path already contains query params (e.g. ?name=small&format=webp),
    # resulting in a malformed URL that Twitter CDN rejects with 404.
    #
    # Example:
    #   http://xn.zpravobot.news:8080/pic/orig/media%2FXXX.jpg%3Fname%3Dsmall
    #   → https://pbs.twimg.com/media/XXX.jpg?name=small
    #
    # @param url [String]
    # @return [String] Direct CDN URL, or original URL if not a Nitter proxy URL
    def resolve_nitter_proxy_url(url)
      nitter = ENV['NITTER_INSTANCE'].to_s.chomp('/')
      return url if nitter.empty? || !url.start_with?(nitter)

      if (m = url.match(%r{/pic/orig/(.+)$}i) || url.match(%r{/pic/(.+)$}i))
        decoded = URI.decode_www_form_component(m[1])
        decoded = "https://pbs.twimg.com/#{decoded}" unless decoded.start_with?('http')
        log "Nitter proxy → CDN: #{decoded}"
        return decoded
      end

      url
    end

    # Percent-encode non-ASCII characters in a URL so URI.parse and HTTP clients
    # can handle URLs with diacritics (e.g. forum24.cz images with Czech filenames).
    # Already-encoded sequences (e.g. %20) are left intact.
    def encode_non_ascii_url(url)
      url.gsub(/[^\x00-\x7F]+/) { |s| s.bytes.map { |b| "%%%02X" % b }.join }
    end

    def validate_credentials!
      raise Zpravobot::ConfigError, "Instance URL required" if instance_url.nil? || instance_url.empty?
      raise Zpravobot::ConfigError, "Access token required" if access_token.nil? || access_token.empty?
    end

    # Raise AccountRateLimitedError if this publisher is currently rate-limited.
    # Used as pre-flight check before publish/upload/update.
    def raise_if_rate_limited!
      return unless rate_limited?
      raise Zpravobot::AccountRateLimitedError.new(
        "Account rate limited for #{rate_limit_remaining}s (until #{@rate_limited_until.strftime('%H:%M:%S')})",
        retry_after: rate_limit_remaining,
        account_id: @instance_url
      )
    end

    # Record rate limit state from a 429 HTTP response and raise AccountRateLimitedError.
    # Called when a live request hits 429 (in publish/update_status); execute_with_retry
    # handles its own 429 path via RateLimitError → AccountRateLimitedError.
    def mark_rate_limited!(response)
      retry_after = (response['Retry-After'] || '5').to_i
      @rate_limited_until = Time.now + retry_after + rand(1..3)
      log "Rate limited (429), marked until #{@rate_limited_until.strftime('%H:%M:%S')} — deferring", level: :warn
      raise Zpravobot::AccountRateLimitedError.new(
        "Rate limited (429), retry after #{retry_after}s",
        retry_after: retry_after,
        account_id: @instance_url
      )
    end

    # ============================================
    # API helpers — delegate to HttpClient
    # ============================================

    def auth_headers
      { 'Authorization' => "Bearer #{access_token}" }
    end

    def api_get(path)
      url = "#{instance_url}#{path}"
      HttpClient.get(url, headers: auth_headers)
    end

    def api_post(path, params)
      url = "#{instance_url}#{path}"
      HttpClient.post_json(url, params, headers: auth_headers)
    end

    def api_put(path, params)
      url = "#{instance_url}#{path}"
      HttpClient.put_json(url, params, headers: auth_headers)
    end

    def api_delete(path)
      url = "#{instance_url}#{path}"
      HttpClient.delete(url, headers: auth_headers)
    end

    # Execute pre-built request with retry for rate limits and server errors
    def execute_with_retry(uri, request)
      retries = 0

      begin
        response = HttpClient.execute(uri, request)

        if response.code.to_i == 429
          retry_after = (response['Retry-After'] || '5').to_i
          raise Zpravobot::RateLimitError.new("Rate limited", retry_after: retry_after)
        end

        if response.code.to_i >= 500
          raise Zpravobot::ServerError.new(status_code: response.code.to_i)
        end

        response

      rescue Zpravobot::RateLimitError => e
        # Non-blocking: record rate limit state and propagate — don't sleep
        @rate_limited_until = Time.now + e.retry_after + rand(1..3)
        log "Rate limited (429), marked until #{@rate_limited_until.strftime('%H:%M:%S')} — deferring to next run", level: :warn
        raise Zpravobot::AccountRateLimitedError.new(
          "Rate limited (429), retry after #{e.retry_after}s",
          retry_after: e.retry_after,
          account_id: @instance_url
        )

      rescue Zpravobot::ServerError => e
        retries += 1
        if retries > MAX_RETRIES_SERVER_ERROR
          log "Server error persists after #{MAX_RETRIES_SERVER_ERROR} retries", level: :error
          return Net::HTTPServiceUnavailable.new('1.1', '503', 'Service Unavailable')
        end

        wait_time = retries + rand(0..2)
        log "Server error (#{e.status_code}), retrying in #{wait_time}s (attempt #{retries}/#{MAX_RETRIES_SERVER_ERROR})...", level: :warn
        sleep wait_time
        retry

      rescue Net::OpenTimeout, Net::ReadTimeout => e
        retries += 1
        if retries > MAX_RETRIES_SERVER_ERROR
          log "Timeout after #{MAX_RETRIES_SERVER_ERROR} retries: #{e.message}", level: :error
          raise
        end

        wait_time = retries + rand(0..2)
        log "Timeout (#{e.class.name}), retrying in #{wait_time}s...", level: :warn
        sleep wait_time
        retry
      end
    end

    # Wait for async media processing to complete (v2 API)
    def wait_for_media_processing(media_id, max_attempts: 10, initial_delay: 1)
      delay = initial_delay
      max_attempts.times do |attempt|
        sleep(delay)

        response = api_get("/api/v1/media/#{media_id}")

        if response.code.to_i == 200
          log "Media #{media_id} ready (after #{attempt + 1} polls)"
          return true
        elsif response.code.to_i == 206 || response.code.to_i == 422
          log "Media #{media_id} still processing (attempt #{attempt + 1}/#{max_attempts}, code: #{response.code})"
          delay = [delay * 1.5, 5].min
        else
          log "Media #{media_id} poll unexpected: #{response.code}", level: :warn
          return false
        end
      end

      log "Media #{media_id} processing timeout after #{max_attempts} attempts", level: :warn
      false
    end

    def build_multipart_body(boundary, data, filename, content_type, description)
      body = "".b
      safe_filename = sanitize_multipart_filename(filename)

      body << "--#{boundary}\r\n".b
      body << "Content-Disposition: form-data; name=\"file\"; filename=\"#{safe_filename}\"\r\n".b
      body << "Content-Type: #{content_type}\r\n\r\n".b
      body << data.b
      body << "\r\n".b

      if description && !description.empty?
        body << "--#{boundary}\r\n".b
        body << "Content-Disposition: form-data; name=\"description\"\r\n\r\n".b
        body << description.to_s.encode('UTF-8').b
        body << "\r\n".b
      end

      body << "--#{boundary}--\r\n".b
      body
    end

    # Filename z URL může po percent-decode obsahovat ", \r, \n nebo jiné
    # znaky, které prolomí Content-Disposition header (uzavření quoted-string,
    # injection nové hlavičky, předčasná terminace multipart části). Redukce
    # na bezpečnou množinu znaků problém eliminuje; pro Mastodon je filename
    # jen technický identifikátor, ne user-facing string. Stejný regex jako
    # Webhook::QueueWriter.sanitize pro konzistenci napříč repem.
    def sanitize_multipart_filename(filename)
      cleaned = filename.to_s.gsub(/[^a-zA-Z0-9._-]/, '_')
      cleaned = 'media' if cleaned.empty?
      cleaned[0, 200]
    end

    # Delegate MIME detection and extension correction to Utils::MimeDetector
    UNSUPPORTED_MEDIA_EXTENSIONS = Utils::MimeDetector::UNSUPPORTED_MEDIA_EXTENSIONS

    def detect_content_type(url, data)
      Utils::MimeDetector.detect_from_url(url, data)
    end

    def detect_content_type_from_path(path, data)
      Utils::MimeDetector.detect_from_path(path, data)
    end

    def correct_filename_extension(filename, content_type)
      Utils::MimeDetector.correct_extension(filename, content_type)
    end

    def parse_error(response)
      JSON.parse(response.body)['error'] rescue response.body
    end

  end
end
