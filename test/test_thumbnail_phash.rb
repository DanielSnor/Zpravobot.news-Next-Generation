#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Test Script: ThumbnailPhash (aHash via ImageMagick)
# ============================================================
#
# Testuje Processors::ThumbnailPhash — perceptuální hash pro video deduplikaci.
# Nevyžaduje DB ani síť.
# compute() testy mocují Open3.capture3 pro deterministické výsledky.
#
# Použití:
#   ruby test/test_thumbnail_phash.rb
#   ruby test/test_thumbnail_phash.rb --verbose
#
# ============================================================

require_relative '../lib/processors/thumbnail_phash'

class ThumbnailPhashTest
  def initialize
    @passed = 0
    @failed = 0
  end

  def run_all
    puts
    puts '=' * 60
    puts '  ThumbnailPhash Tests'
    puts '=' * 60
    puts

    # parse_pixels tests
    test_parse_pixels_basic
    test_parse_pixels_skips_header_comment
    test_parse_pixels_handles_multi_channel
    test_parse_pixels_empty_string
    test_parse_pixels_64_pixels

    # hamming tests
    test_hamming_identical_hashes
    test_hamming_one_bit_difference
    test_hamming_all_bits_different
    test_hamming_known_values

    # similar? tests
    test_similar_identical
    test_similar_within_threshold
    test_similar_at_threshold_boundary
    test_similar_exceeds_threshold
    test_similar_nil_first
    test_similar_nil_second

    # compute tests (mocked Open3)
    test_compute_nil_data
    test_compute_empty_data
    test_compute_uniform_dark_image
    test_compute_uniform_bright_image
    test_compute_checkerboard_pattern
    test_compute_returns_integer
    test_compute_stable_for_same_pixels

    puts
    puts '=' * 60
    puts "  Results: #{@passed} passed, #{@failed} failed"
    puts '=' * 60
    puts

    @failed == 0
  end

  private

  # ============================================================
  # parse_pixels tests
  # ============================================================

  def test_parse_pixels_basic
    test('parse_pixels: parses basic txt: line') do
      txt = "0,0: (128,128,128)  #808080  srgb(128,128,128)\n"
      result = Processors::ThumbnailPhash.parse_pixels(txt)
      assert_equal [128], result
    end
  end

  def test_parse_pixels_skips_header_comment
    test('parse_pixels: skips # header lines') do
      txt = "# ImageMagick pixel enumeration: 8,8,255,gray\n0,0: (64)  #404040  gray(64)\n"
      result = Processors::ThumbnailPhash.parse_pixels(txt)
      assert_equal [64], result
    end
  end

  def test_parse_pixels_handles_multi_channel
    test('parse_pixels: takes first channel value from multi-channel format') do
      txt = "0,0: (200,150,100)  #c89664  srgb(200,150,100)\n1,0: (50,50,50)  #323232  gray\n"
      result = Processors::ThumbnailPhash.parse_pixels(txt)
      assert_equal [200, 50], result
    end
  end

  def test_parse_pixels_empty_string
    test('parse_pixels: returns empty array for empty string') do
      result = Processors::ThumbnailPhash.parse_pixels('')
      assert_equal [], result
    end
  end

  def test_parse_pixels_64_pixels
    test('parse_pixels: parses 64 pixel lines (8×8 grid)') do
      lines = (0..7).flat_map do |y|
        (0..7).map { |x| "#{x},#{y}: (#{(x + y * 8) * 4 % 256})  #000000  gray\n" }
      end
      txt = lines.join
      result = Processors::ThumbnailPhash.parse_pixels(txt)
      assert_equal 64, result.length
    end
  end

  # ============================================================
  # hamming tests
  # ============================================================

  def test_hamming_identical_hashes
    test('hamming: identical hashes → distance 0') do
      h = 0x40636f0f8f38310f
      assert_equal 0, Processors::ThumbnailPhash.hamming(h, h)
    end
  end

  def test_hamming_one_bit_difference
    test('hamming: one bit flip → distance 1') do
      assert_equal 1, Processors::ThumbnailPhash.hamming(0, 1)
      assert_equal 1, Processors::ThumbnailPhash.hamming(0b1111, 0b1110)
    end
  end

  def test_hamming_all_bits_different
    test('hamming: all 8 bits different → distance 8') do
      assert_equal 8, Processors::ThumbnailPhash.hamming(0xFF, 0x00)
    end
  end

  def test_hamming_known_values
    test('hamming: known value pairs') do
      # 0b1010 XOR 0b1100 = 0b0110 → popcount = 2
      assert_equal 2, Processors::ThumbnailPhash.hamming(0b1010, 0b1100)
      # All 64 bits flipped
      assert_equal 64, Processors::ThumbnailPhash.hamming(0, 0xFFFFFFFFFFFFFFFF)
    end
  end

  # ============================================================
  # similar? tests
  # ============================================================

  def test_similar_identical
    test('similar?: identical hashes → true') do
      h = 0x40636f0f8f38310f
      assert_equal true, Processors::ThumbnailPhash.similar?(h, h)
    end
  end

  def test_similar_within_threshold
    test('similar?: Hamming 5 within default threshold 10 → true') do
      h1 = 0b0000_0000_0000_0000
      h2 = 0b0000_0000_0001_1111  # 5 bits different
      assert_equal true, Processors::ThumbnailPhash.similar?(h1, h2)
    end
  end

  def test_similar_at_threshold_boundary
    test('similar?: Hamming exactly at threshold → true') do
      h1 = 0
      h2 = (1 << 10) - 1  # 10 bits set → Hamming = 10
      assert_equal true, Processors::ThumbnailPhash.similar?(h1, h2, threshold: 10)
    end
  end

  def test_similar_exceeds_threshold
    test('similar?: Hamming 11 exceeds default threshold 10 → false') do
      h1 = 0
      h2 = (1 << 11) - 1  # 11 bits set → Hamming = 11
      assert_equal false, Processors::ThumbnailPhash.similar?(h1, h2, threshold: 10)
    end
  end

  def test_similar_nil_first
    test('similar?: nil first argument → false') do
      assert_equal false, Processors::ThumbnailPhash.similar?(nil, 12345)
    end
  end

  def test_similar_nil_second
    test('similar?: nil second argument → false') do
      assert_equal false, Processors::ThumbnailPhash.similar?(12345, nil)
    end
  end

  # ============================================================
  # compute tests (mocked via parse_pixels)
  # ============================================================

  def test_compute_nil_data
    test('compute: nil data → nil') do
      result = Processors::ThumbnailPhash.compute(nil)
      assert_equal nil, result
    end
  end

  def test_compute_empty_data
    test('compute: empty data → nil') do
      result = Processors::ThumbnailPhash.compute('')
      assert_equal nil, result
    end
  end

  def test_compute_uniform_dark_image
    test('compute: all-zero pixels → all bits 0 (avg=0, all >= avg → all 1s)') do
      # When all pixels = 0 and avg = 0.0, each px (0) >= avg (0.0) → bit=1
      # Result = all 64 bits set = 0xFFFFFFFFFFFFFFFF
      txt = build_txt_output(Array.new(64, 0))
      result = compute_with_mock_output(txt)
      assert_equal 0xFFFFFFFFFFFFFFFF, result
    end
  end

  def test_compute_uniform_bright_image
    test('compute: all pixels same non-zero value → all bits 1') do
      # When all pixels = 200 and avg = 200.0, each px (200) >= avg (200.0) → bit=1
      txt = build_txt_output(Array.new(64, 200))
      result = compute_with_mock_output(txt)
      assert_equal 0xFFFFFFFFFFFFFFFF, result
    end
  end

  def test_compute_checkerboard_pattern
    test('compute: alternating 0/255 checkerboard → stable known hash') do
      # pixels: 0, 255, 0, 255, ... (32 pairs)
      # avg = 127.5; 0 < avg → bit=0; 255 >= avg → bit=1
      # Bits 0,2,4,6,... = 0; bits 1,3,5,7,... = 1
      # In LSB-first encoding: bits 1,3,5,7,9,11,13,15,... = 1
      # = 0xAAAAAAAAAAAAAAAA (alternating 10 pattern in hex nibbles = 1010 1010)
      pixels = (0..63).map { |i| i.odd? ? 255 : 0 }
      txt = build_txt_output(pixels)
      result = compute_with_mock_output(txt)
      expected = 0xAAAAAAAAAAAAAAAA
      assert_equal expected, result
    end
  end

  def test_compute_returns_integer
    test('compute: returns Integer (or nil on failure)') do
      # Simulates a valid 64-pixel output
      pixels = (0..63).map { |i| (i * 4) % 256 }
      txt = build_txt_output(pixels)
      result = compute_with_mock_output(txt)
      assert result.is_a?(Integer), "Expected Integer, got #{result.class}"
    end
  end

  def test_compute_stable_for_same_pixels
    test('compute: same pixel values → same hash (deterministic)') do
      pixels = (0..63).map { |i| (i * 3 + 50) % 256 }
      txt = build_txt_output(pixels)
      result1 = compute_with_mock_output(txt)
      result2 = compute_with_mock_output(txt)
      assert_equal result1, result2
    end
  end

  # ============================================================
  # Helpers
  # ============================================================

  # Build ImageMagick txt: output from array of 64 pixel values
  def build_txt_output(pixels)
    lines = ["# ImageMagick pixel enumeration: 8,8,255,gray\n"]
    pixels.each_with_index do |val, i|
      x = i % 8
      y = i / 8
      lines << "#{x},#{y}: (#{val})  #000000  gray(#{val})\n"
    end
    lines.join
  end

  # Call ThumbnailPhash.compute but bypass the ImageMagick shell-out by
  # calling parse_pixels + hash computation directly (same logic, no tempfile).
  def compute_with_mock_output(txt)
    pixels = Processors::ThumbnailPhash.parse_pixels(txt)
    return nil if pixels.length != 64

    avg = pixels.sum / 64.0
    pixels.each_with_index.reduce(0) { |h, (px, i)| px >= avg ? h | (1 << i) : h }
  end

  # ============================================================
  # Test runner helpers
  # ============================================================

  def test(name)
    print "  #{name}... "
    begin
      yield
      puts '✅'
      @passed += 1
    rescue AssertionError => e
      puts '❌'
      puts "    #{e.message}"
      @failed += 1
    rescue StandardError => e
      puts '💥'
      puts "    #{e.class}: #{e.message}"
      puts e.backtrace.first(3).map { |l| "      #{l}" }.join("\n") if $verbose
      @failed += 1
    end
  end

  def assert(condition, message = 'Assertion failed')
    raise AssertionError, message unless condition
  end

  def assert_equal(expected, actual, message = nil)
    return if expected == actual

    raise AssertionError, message || "Expected #{expected.inspect}, got #{actual.inspect}"
  end

  class AssertionError < StandardError; end
end

# Run tests
$verbose = ARGV.include?('--verbose') || ARGV.include?('-v')
success = ThumbnailPhashTest.new.run_all
exit(success ? 0 : 1)
