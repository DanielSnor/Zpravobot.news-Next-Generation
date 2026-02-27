#!/usr/bin/env ruby
# frozen_string_literal: true

# Profile Sync Test - Bluesky → Mastodon
#
# Location: /app/data/zbnw-ng-test/bin/test_profile_sync.rb
#
# Usage:
#   ruby bin/test_profile_sync.rb preview           # Show what would be synced
#   ruby bin/test_profile_sync.rb sync              # Sync all (bio, avatar, banner)
#   ruby bin/test_profile_sync.rb sync --bio-only   # Sync only bio
#   ruby bin/test_profile_sync.rb sync --avatar-only
#   ruby bin/test_profile_sync.rb sync --banner-only

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

begin
  require 'syncers/profile_syncer'
rescue LoadError
  puts "⚠️  syncers/profile_syncer not found - use platform-specific syncers instead"
  puts "   (bluesky_profile_syncer, twitter_profile_syncer, facebook_profile_syncer)"
  puts "   Skipping test_profile_sync.rb"
  exit 0
end

require 'yaml'

# ==============================================================================
# Configuration
# ==============================================================================

# Edit these for your setup:
BLUESKY_HANDLE = 'nesestra.bsky.social'
MASTODON_CONFIG_PATH = 'config/mastodon.yml'

# ==============================================================================
# Helper Methods
# ==============================================================================

def separator(char = '=', length = 60)
  puts char * length
end

def load_mastodon_config
  unless File.exist?(MASTODON_CONFIG_PATH)
    puts "❌ Mastodon config not found: #{MASTODON_CONFIG_PATH}"
    exit 1
  end
  
  config = YAML.load_file(MASTODON_CONFIG_PATH)
  
  {
    instance_url: config['instance_url'] || config[:instance_url],
    access_token: config['access_token'] || config[:access_token]
  }
end

# ==============================================================================
# Commands
# ==============================================================================

def cmd_preview(syncer)
  puts
  puts "🔍 Profile Preview: @#{BLUESKY_HANDLE}"
  separator
  puts
  
  profile = syncer.preview
  
  puts
  separator
  puts "This data would be synced to Mastodon."
  puts "Run 'ruby bin/test_profile_sync.rb sync' to apply."
end

def cmd_sync(syncer, options)
  puts
  puts "🔄 Profile Sync: Bluesky → Mastodon"
  separator
  puts
  
  sync_avatar = !options[:bio_only] && !options[:banner_only]
  sync_banner = !options[:bio_only] && !options[:avatar_only]
  sync_bio = !options[:avatar_only] && !options[:banner_only]
  sync_bsky_field = !options[:bio_only] && !options[:avatar_only] && !options[:banner_only]
  
  if options[:bio_only]
    puts "Mode: Bio only"
  elsif options[:avatar_only]
    puts "Mode: Avatar only"
  elsif options[:banner_only]
    puts "Mode: Banner only"
  else
    puts "Mode: Full sync (bio + avatar + banner + bsky field)"
  end
  puts
  
  print "Continue? (y/N): "
  confirm = $stdin.gets&.strip&.downcase
  
  unless confirm == 'y'
    puts "Cancelled"
    return
  end
  
  puts
  result = syncer.sync!(
    sync_avatar: sync_avatar,
    sync_banner: sync_banner,
    sync_bio: sync_bio,
    sync_bsky_field: sync_bsky_field
  )
  
  puts
  separator
  if result[:success]
    puts "✅ Sync completed!"
    puts "   Changes: #{result[:changes].join(', ')}"
  else
    puts "❌ Sync failed: #{result[:error]}"
  end
end

# ==============================================================================
# Main
# ==============================================================================

def main
  command = ARGV[0] || 'help'
  
  case command
  when 'preview'
    mastodon_config = load_mastodon_config
    syncer = Syncers::ProfileSyncer.new(
      bluesky_handle: BLUESKY_HANDLE,
      mastodon_instance: mastodon_config[:instance_url],
      mastodon_token: mastodon_config[:access_token]
    )
    cmd_preview(syncer)
    
  when 'sync'
    mastodon_config = load_mastodon_config
    syncer = Syncers::ProfileSyncer.new(
      bluesky_handle: BLUESKY_HANDLE,
      mastodon_instance: mastodon_config[:instance_url],
      mastodon_token: mastodon_config[:access_token]
    )
    
    options = {
      bio_only: ARGV.include?('--bio-only'),
      avatar_only: ARGV.include?('--avatar-only'),
      banner_only: ARGV.include?('--banner-only')
    }
    
    cmd_sync(syncer, options)
    
  else
    puts
    puts "Profile Sync - Bluesky → Mastodon"
    separator
    puts
    puts "Usage:"
    puts "  ruby bin/test_profile_sync.rb preview           # Show what would be synced"
    puts "  ruby bin/test_profile_sync.rb sync              # Sync all"
    puts "  ruby bin/test_profile_sync.rb sync --bio-only   # Sync only bio"
    puts "  ruby bin/test_profile_sync.rb sync --avatar-only"
    puts "  ruby bin/test_profile_sync.rb sync --banner-only"
    puts
    puts "Configuration:"
    puts "  Bluesky: @#{BLUESKY_HANDLE}"
    puts "  Config:  #{MASTODON_CONFIG_PATH}"
    puts
    puts "Edit BLUESKY_HANDLE in this script to change source account."
  end
end

main
