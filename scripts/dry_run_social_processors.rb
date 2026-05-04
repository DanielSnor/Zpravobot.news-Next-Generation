#!/usr/bin/env ruby
# frozen_string_literal: true
# encoding: utf-8

# ============================================================
# Dry-run sociálních procesorů na uložených RSS.app vzorcích
# ============================================================
#
# Pustí FacebookProcessor a InstagramProcessor přes RSS.app feedy
# uložené v test/fixtures/ a vypíše vstup vs. výstup pro každou
# změněnou položku — pro vizuální kontrolu při ladění heuristik.
#
# Použití:
#   ruby scripts/dry_run_social_processors.rb              # oba procesory
#   ruby scripts/dry_run_social_processors.rb --fb         # jen FB
#   ruby scripts/dry_run_social_processors.rb --ig         # jen IG
#   ruby scripts/dry_run_social_processors.rb --all        # i nezměněné položky
#
# Pro refresh vzorků:
#   curl -sL https://rss.app/feeds/_1eXG8ArqWY91MVT2.xml > test/fixtures/rss_app_facebook_sample.xml
#   curl -sL https://rss.app/feeds/_lji8ZdZarMmmKa4T.xml > test/fixtures/rss_app_instagram_sample.xml
# ============================================================

require 'rexml/document'

ROOT = File.expand_path('..', __dir__)
$LOAD_PATH.unshift File.join(ROOT, 'lib')

require 'processors/instagram_processor'
require 'processors/facebook_processor'

show_unchanged = ARGV.include?('--all')
run_fb = ARGV.include?('--fb') || (!ARGV.include?('--ig') && !ARGV.include?('--fb'))
run_ig = ARGV.include?('--ig') || (!ARGV.include?('--ig') && !ARGV.include?('--fb'))

def dump_feed(label, fixture_path, processor, show_unchanged:)
  unless File.exist?(fixture_path)
    warn "Fixture missing: #{fixture_path}"
    return
  end

  doc = REXML::Document.new(File.read(fixture_path))
  items = doc.elements.to_a('rss/channel/item')

  puts '=' * 70
  puts "# #{label}  —  #{items.length} items  (#{File.basename(fixture_path)})"
  puts '=' * 70

  changed = 0
  items.each_with_index do |item, i|
    desc = item.elements['description']&.text
    next if desc.nil? || desc.empty?

    src = item.elements['source']&.text || item.elements['dc:creator']&.text
    out = processor.process(desc)
    same = (out == desc)
    next if same && !show_unchanged

    changed += 1 unless same
    status = same ? 'unchanged' : 'CHANGED'
    puts
    puts "── ITEM #{i + 1}  (#{src})  [#{status}]"
    puts "INPUT:  #{desc}"
    puts 'OUTPUT:'
    out.each_line { |l| puts "  | #{l.chomp}" }
  end

  puts
  puts "Changed: #{changed}/#{items.length} items"
  puts
end

fixtures_dir = File.join(ROOT, 'test', 'fixtures')

if run_fb
  dump_feed('FB feed', File.join(fixtures_dir, 'rss_app_facebook_sample.xml'),
           Processors::FacebookProcessor.new, show_unchanged: show_unchanged)
end

if run_ig
  dump_feed('IG feed', File.join(fixtures_dir, 'rss_app_instagram_sample.xml'),
           Processors::InstagramProcessor.new, show_unchanged: show_unchanged)
end
