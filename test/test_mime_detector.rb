#!/usr/bin/env ruby
# frozen_string_literal: true

# Test Utils::MimeDetector — magic byte detection, extension fallback,
# filename extension correction. Vše offline (žádné HTTP, žádné disk I/O).
#
# Tato testovací sada byla vyčleněna z test_mastodon_publisher.rb po R5
# refaktoru (extrakce MimeDetector modulu). Publisher má i nadále delegáty
# pro detect_content_type / detect_content_type_from_path / correct_filename_extension,
# které testuje test_mastodon_publisher.rb; tady testujeme samotný modul.
#
# Run: ruby test/test_mime_detector.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/utils/mime_detector'

puts "=" * 60
puts "Utils::MimeDetector Tests (offline)"
puts "=" * 60
puts

$passed = 0
$failed = 0

def test(name, expected, actual)
  if expected == actual
    puts "  \e[32m✓\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m✗\e[0m #{name}"
    puts "    Expected: #{expected.inspect}"
    puts "    Actual:   #{actual.inspect}"
    $failed += 1
  end
end

def section(title)
  puts
  puts "--- #{title} ---"
end

# Magic byte fixtures — common prefixy doplněné výplní, aby byly delší než
# parser potřebuje. Stejné fixtures historicky v test_mastodon_publisher.rb.
JPEG_MAGIC  = ("\xFF\xD8\xFF\xE0" + ('x' * 20)).b
PNG_MAGIC   = ("\x89PNG\r\n\x1A\n" + ('x' * 20)).b
GIF89_MAGIC = ("GIF89a" + ('x' * 20)).b
GIF87_MAGIC = ("GIF87a" + ('x' * 20)).b
WEBP_MAGIC  = ("RIFF\x00\x00\x00\x00WEBP" + ('x' * 20)).b
MP4_MAGIC   = ("\x00\x00\x00\x20ftypisom" + ('x' * 20)).b
WEBM_MAGIC  = ("\x1A\x45\xDF\xA3" + ('x' * 20)).b
DUMMY_DATA  = ('x' * 20).b  # žádné magic bytes — vynutí extension fallback

# =============================================================================
# Constants
# =============================================================================
section("Constants")

test("UNSUPPORTED_MEDIA_EXTENSIONS obsahuje mp3", true,
     Utils::MimeDetector::UNSUPPORTED_MEDIA_EXTENSIONS.include?('.mp3'))
test("UNSUPPORTED_MEDIA_EXTENSIONS obsahuje m3u8 (HLS playlist)", true,
     Utils::MimeDetector::UNSUPPORTED_MEDIA_EXTENSIONS.include?('.m3u8'))
test("EXTENSION_MIME_MAP má .jpg → image/jpeg", 'image/jpeg',
     Utils::MimeDetector::EXTENSION_MIME_MAP['.jpg'])
test("MIME_EXTENSION_MAP má image/png → .png", '.png',
     Utils::MimeDetector::MIME_EXTENSION_MAP['image/png'])

# =============================================================================
# from_bytes (magic byte detection)
# =============================================================================
section("from_bytes — magic byte detection")

test("JPEG magic bytes", 'image/jpeg', Utils::MimeDetector.from_bytes(JPEG_MAGIC))
test("PNG magic bytes", 'image/png', Utils::MimeDetector.from_bytes(PNG_MAGIC))
test("GIF89a magic bytes", 'image/gif', Utils::MimeDetector.from_bytes(GIF89_MAGIC))
test("GIF87a magic bytes", 'image/gif', Utils::MimeDetector.from_bytes(GIF87_MAGIC))
test("WEBP magic bytes (RIFF...WEBP)", 'image/webp', Utils::MimeDetector.from_bytes(WEBP_MAGIC))
test("MP4 ftyp magic bytes", 'video/mp4', Utils::MimeDetector.from_bytes(MP4_MAGIC))
test("WebM magic bytes", 'video/webm', Utils::MimeDetector.from_bytes(WEBM_MAGIC))

test("nil data returns nil", nil, Utils::MimeDetector.from_bytes(nil))
test("empty data returns nil", nil, Utils::MimeDetector.from_bytes(''))
test("unknown bytes returns nil", nil, Utils::MimeDetector.from_bytes('x' * 20))

# Edge case: RIFF header bez WEBP marker (např. WAV) nesmí matchnout jako WEBP
riff_non_webp = ("RIFF\x00\x00\x00\x00WAVE" + ('x' * 20)).b
test("RIFF s non-WEBP markerem nematchne webp", nil, Utils::MimeDetector.from_bytes(riff_non_webp))

# Edge case: krátká data nesmí způsobit out-of-bounds match
test("krátká data (3 bajty) — žádný match", nil, Utils::MimeDetector.from_bytes("\xFF\xD8\xFF".b[0..1]))

# =============================================================================
# from_extension (lookup)
# =============================================================================
section("from_extension — extension lookup")

test(".jpg → image/jpeg", 'image/jpeg', Utils::MimeDetector.from_extension('.jpg'))
test(".jpeg → image/jpeg", 'image/jpeg', Utils::MimeDetector.from_extension('.jpeg'))
test(".png → image/png", 'image/png', Utils::MimeDetector.from_extension('.png'))
test(".gif → image/gif", 'image/gif', Utils::MimeDetector.from_extension('.gif'))
test(".webp → image/webp", 'image/webp', Utils::MimeDetector.from_extension('.webp'))
test(".mp4 → video/mp4", 'video/mp4', Utils::MimeDetector.from_extension('.mp4'))
test(".webm → video/webm", 'video/webm', Utils::MimeDetector.from_extension('.webm'))
test(".mov → video/quicktime", 'video/quicktime', Utils::MimeDetector.from_extension('.mov'))

test("neznámá extension → nil", nil, Utils::MimeDetector.from_extension('.xyz'))
test("prázdný string → nil", nil, Utils::MimeDetector.from_extension(''))

# =============================================================================
# detect_from_url (content-first, URL extension fallback)
# =============================================================================
section("detect_from_url — magic wins, extension fallback")

# Magic bytes win i přes špatnou extension
test("PNG bytes + .jpg ext → image/png (content wins)", 'image/png',
     Utils::MimeDetector.detect_from_url('https://example.com/pic.jpg', PNG_MAGIC))
test("JPEG bytes + .png ext → image/jpeg (content wins)", 'image/jpeg',
     Utils::MimeDetector.detect_from_url('https://example.com/pic.png', JPEG_MAGIC))
test("WebP bytes + .jpg ext → image/webp (content wins)", 'image/webp',
     Utils::MimeDetector.detect_from_url('https://example.com/pic.jpg', WEBP_MAGIC))
test("MP4 bytes + .jpg ext → video/mp4 (content wins)", 'video/mp4',
     Utils::MimeDetector.detect_from_url('https://example.com/pic.jpg', MP4_MAGIC))

# Extension fallback (žádné magic bytes)
test("dummy data + .jpg → image/jpeg (ext fallback)", 'image/jpeg',
     Utils::MimeDetector.detect_from_url('https://example.com/pic.jpg', DUMMY_DATA))
test("dummy data + .png → image/png", 'image/png',
     Utils::MimeDetector.detect_from_url('https://example.com/pic.png', DUMMY_DATA))
test("dummy data + .mp4 → video/mp4", 'video/mp4',
     Utils::MimeDetector.detect_from_url('https://example.com/vid.mp4', DUMMY_DATA))

# Magic bytes + bez extension
test("JPEG bytes + bez ext → image/jpeg", 'image/jpeg',
     Utils::MimeDetector.detect_from_url('https://example.com/noext', JPEG_MAGIC))

# Unknown content + unknown extension → octet-stream
test("dummy + .xyz → application/octet-stream", 'application/octet-stream',
     Utils::MimeDetector.detect_from_url('https://example.com/file.xyz', DUMMY_DATA))

# URL parse failure nesmí způsobit exception — fallback na octet-stream
test("malformed URL → application/octet-stream (no exception)", 'application/octet-stream',
     Utils::MimeDetector.detect_from_url('not a url at all', DUMMY_DATA))

# Query parameters v URL nesmí zmást extension lookup
test(".jpg?query=x → image/jpeg", 'image/jpeg',
     Utils::MimeDetector.detect_from_url('https://example.com/pic.jpg?v=1', DUMMY_DATA))

# =============================================================================
# detect_from_path (content-first, file path extension fallback)
# =============================================================================
section("detect_from_path — file path varianta")

test("/path/image.jpg + dummy → image/jpeg", 'image/jpeg',
     Utils::MimeDetector.detect_from_path('/path/image.jpg', DUMMY_DATA))
test("/path/image.png + dummy → image/png", 'image/png',
     Utils::MimeDetector.detect_from_path('/path/image.png', DUMMY_DATA))
test("relative path photo.gif + dummy → image/gif", 'image/gif',
     Utils::MimeDetector.detect_from_path('photo.gif', DUMMY_DATA))

# Content wins
test("path .jpg + PNG content → image/png", 'image/png',
     Utils::MimeDetector.detect_from_path('/path/image.jpg', PNG_MAGIC))
test("path .png + JPEG content → image/jpeg", 'image/jpeg',
     Utils::MimeDetector.detect_from_path('/path/image.png', JPEG_MAGIC))

test("unknown path + dummy → application/octet-stream", 'application/octet-stream',
     Utils::MimeDetector.detect_from_path('/path/file.xyz', DUMMY_DATA))

# =============================================================================
# correct_extension (filename extension korekce podle MIME)
# =============================================================================
section("correct_extension — filename align s detekovaným MIME")

# Extension odpovídá content type → no change
test("image.jpg + image/jpeg → image.jpg", 'image.jpg',
     Utils::MimeDetector.correct_extension('image.jpg', 'image/jpeg'))
test("image.jpeg + image/jpeg → image.jpeg (alias zachován)", 'image.jpeg',
     Utils::MimeDetector.correct_extension('image.jpeg', 'image/jpeg'))
test("photo.png + image/png → photo.png", 'photo.png',
     Utils::MimeDetector.correct_extension('photo.png', 'image/png'))

# Extension neodpovídá → korekce
test("image.jpg + image/png → image.png", 'image.png',
     Utils::MimeDetector.correct_extension('image.jpg', 'image/png'))
test("photo.jpg + image/webp → photo.webp", 'photo.webp',
     Utils::MimeDetector.correct_extension('photo.jpg', 'image/webp'))
test("video.jpg + video/mp4 → video.mp4", 'video.mp4',
     Utils::MimeDetector.correct_extension('video.jpg', 'video/mp4'))

# Bez extension → přidá korektní
test("media + image/jpeg → media.jpg", 'media.jpg',
     Utils::MimeDetector.correct_extension('media', 'image/jpeg'))
test("file + image/png → file.png", 'file.png',
     Utils::MimeDetector.correct_extension('file', 'image/png'))

# Unknown content type → no change
test("image.jpg + text/html → image.jpg (unknown MIME nezasahuje)", 'image.jpg',
     Utils::MimeDetector.correct_extension('image.jpg', 'text/html'))

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
