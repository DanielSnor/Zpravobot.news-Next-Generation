# frozen_string_literal: true

require 'open3'
require 'tempfile'

module Processors
  # Perceptual hashing (aHash — Average Hash) for video frames via ImageMagick
  #
  # Extracts the first frame of a video, resizes to 8×8 grayscale, computes
  # a 64-bit integer fingerprint (1 bit per pixel: >= average → 1, else → 0).
  #
  # Resistant to re-encoding, slight cropping and compression artefacts.
  # Two hashes with Hamming distance ≤ 10 are considered the same video.
  #
  # Requirements:
  #   ImageMagick `convert` must be in PATH (available at /usr/bin/convert).
  #
  # Usage:
  #   phash = ThumbnailPhash.compute(video_binary_data)
  #   ThumbnailPhash.similar?(phash1, phash2)           # => true/false
  #   ThumbnailPhash.hamming(phash1, phash2)            # => Integer (0..64)
  #
  module ThumbnailPhash
    # Hamming distance threshold for "same video" decision
    HAMMING_THRESHOLD = 10

    # Compute aHash from video binary data
    #
    # @param video_data [String] Binary video content
    # @return [Integer, nil] 64-bit hash integer, or nil on failure
    def self.compute(video_data)
      return nil if video_data.nil? || video_data.empty?

      Tempfile.create(['phash_', '.mp4']) do |f|
        f.binmode
        f.write(video_data)
        f.flush

        stdout, _stderr, status = Open3.capture3(
          'convert', "#{f.path}[0]",
          '-resize', '8x8!',
          '-colorspace', 'Gray',
          '-depth', '8',
          'txt:-'
        )
        return nil unless status.success?

        pixels = parse_pixels(stdout)
        return nil if pixels.length != 64

        avg = pixels.sum / 64.0
        pixels.each_with_index.reduce(0) { |h, (px, i)| px >= avg ? h | (1 << i) : h }
      end
    rescue StandardError
      nil
    end

    # Compute Hamming distance between two hashes (number of differing bits)
    #
    # @param h1 [Integer] First hash
    # @param h2 [Integer] Second hash
    # @return [Integer] Number of differing bits (0..64)
    def self.hamming(h1, h2)
      (h1 ^ h2).to_s(2).count('1')
    end

    # Check whether two hashes represent the same video (Hamming ≤ threshold)
    #
    # @param h1 [Integer, nil] First hash
    # @param h2 [Integer, nil] Second hash
    # @param threshold [Integer] Maximum allowed Hamming distance (default 10)
    # @return [Boolean]
    def self.similar?(h1, h2, threshold: HAMMING_THRESHOLD)
      return false if h1.nil? || h2.nil?

      hamming(h1, h2) <= threshold
    end

    # Parse pixel values from ImageMagick txt: output
    #
    # Format: "x,y: (v,v,v)  #rrggbb  ..."  (one line per pixel, skipping header)
    # For Gray colorspace, all channels equal — we take the first number in parens.
    #
    # @param txt [String] ImageMagick txt: output
    # @return [Array<Integer>] Pixel intensities 0..255, length = width×height
    def self.parse_pixels(txt)
      pixels = []
      txt.each_line do |line|
        next if line.start_with?('#')
        next unless line =~ /\((\d+)/

        pixels << line[/\((\d+)/, 1].to_i
      end
      pixels
    end
  end
end
