# frozen_string_literal: true

require 'uri'

module Utils
  # MIME type detection for media uploads.
  # Primary: magic byte detection from binary content.
  # Fallback: file extension from URL or path.
  module MimeDetector
    # Extensions that Mastodon doesn't support as attachments — skip silently
    UNSUPPORTED_MEDIA_EXTENSIONS = %w[.mp3 .wav .ogg .aac .flac .m4a .wma .opus .m3u8 .m3u].freeze

    EXTENSION_MIME_MAP = {
      '.jpg'  => 'image/jpeg',
      '.jpeg' => 'image/jpeg',
      '.png'  => 'image/png',
      '.gif'  => 'image/gif',
      '.webp' => 'image/webp',
      '.mp4'  => 'video/mp4',
      '.webm' => 'video/webm',
      '.mov'  => 'video/quicktime'
    }.freeze

    MIME_EXTENSION_MAP = {
      'image/jpeg'      => '.jpg',
      'image/png'       => '.png',
      'image/gif'       => '.gif',
      'image/webp'      => '.webp',
      'video/mp4'       => '.mp4',
      'video/webm'      => '.webm',
      'video/quicktime' => '.mov'
    }.freeze

    module_function

    # Detect MIME type from binary content (magic bytes) with URL extension fallback.
    # @param url [String] Used for extension fallback only
    # @param data [String] Binary file data
    # @return [String] MIME type, or 'application/octet-stream' if unknown
    def detect_from_url(url, data)
      ext = begin; File.extname(URI.parse(url).path).downcase; rescue StandardError; ''; end
      from_bytes(data) || from_extension(ext) || 'application/octet-stream'
    end

    # Detect MIME type from binary content with file path extension fallback.
    # @param path [String] File path (used for extension fallback)
    # @param data [String] Binary file data
    # @return [String] MIME type, or 'application/octet-stream' if unknown
    def detect_from_path(path, data)
      from_bytes(data) ||
        from_extension(File.extname(path).downcase) ||
        'application/octet-stream'
    end

    # Detect MIME type from magic bytes.
    # @return [String, nil] MIME type or nil if unrecognized
    def from_bytes(data)
      return nil if data.nil? || data.empty?

      bytes = data.b
      if    bytes[0..2]  == "\xFF\xD8\xFF".b                              then 'image/jpeg'
      elsif bytes[0..7]  == "\x89PNG\r\n\x1A\n".b                         then 'image/png'
      elsif bytes[0..5]  == "GIF89a".b || bytes[0..5] == "GIF87a".b       then 'image/gif'
      elsif bytes[0..3]  == "RIFF".b && bytes.length > 11 &&
            bytes[8..11] == "WEBP".b                                       then 'image/webp'
      elsif bytes.length > 7 && bytes[4..7] == "ftyp".b                   then 'video/mp4'
      elsif bytes[0..3]  == "\x1A\x45\xDF\xA3".b                          then 'video/webm'
      end
    end

    # Map file extension to MIME type.
    # @return [String, nil]
    def from_extension(ext)
      EXTENSION_MIME_MAP[ext]
    end

    # Ensure filename extension matches detected MIME type.
    # Replaces mismatched extension with the correct one.
    def correct_extension(filename, content_type)
      correct_ext = MIME_EXTENSION_MAP[content_type]
      return filename unless correct_ext

      current_ext = File.extname(filename).downcase
      expected    = EXTENSION_MIME_MAP.select { |_, v| v == content_type }.keys

      if expected.include?(current_ext)
        filename
      elsif current_ext.empty?
        "#{filename}#{correct_ext}"
      else
        "#{File.basename(filename, current_ext)}#{correct_ext}"
      end
    end
  end
end
