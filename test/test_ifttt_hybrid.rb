#!/usr/bin/env ruby
# frozen_string_literal: true

# IFTTT Hybrid Testing Tool for Zpravobot Next Generation
#
# Simuluje IFTTT webhooky pro testování tier rozhodovací logiky,
# formátování a celého pipeline bez skutečné publikace.
#
# Location: /app/data/zbnw-ng/bin/test_ifttt_hybrid.rb
#
# Usage:
#   # Test single payload
#   ruby bin/test_ifttt_hybrid.rb --payload '{"text":"...", "username":"ct24zive", ...}'
#
#   # Test from file
#   ruby bin/test_ifttt_hybrid.rb --file test_payloads/short_tweet.json
#
#   # Test all sample payloads
#   ruby bin/test_ifttt_hybrid.rb --samples
#
#   # Send to webhook server (integration test)
#   ruby bin/test_ifttt_hybrid.rb --send --url http://localhost:8089/api/ifttt/twitter
#
#   # Analyze tier distribution from sample data
#   ruby bin/test_ifttt_hybrid.rb --analyze

require 'json'
require 'optparse'
require 'net/http'
require 'uri'

# Add lib to load path
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require_relative '../lib/adapters/twitter_nitter_adapter'

module Testing
  class IftttHybridTester
    # Sample payloads representing different tweet types
    SAMPLE_PAYLOADS = {
      # Tier 1: Short tweets (should NOT trigger Nitter fetch)
      short_regular: {
        description: "Short regular tweet (Tier 1)",
        expected_tier: 1,
        payload: {
          "text" => "Krátký tweet bez jakýchkoliv problémů.",
          "link_to_tweet" => "https://x.com/testuser/status/1234567890123456789",
          "first_link_url" => "",
          "username" => "testuser",
          "embed_code" => "<p>Krátký tweet bez jakýchkoliv problémů.</p>"
        }
      },
      
      short_with_url: {
        description: "Short tweet ending with URL (Tier 1)",
        expected_tier: 1,
        payload: {
          "text" => "Podívejte se na tento článek https://example.com/clanek",
          "link_to_tweet" => "https://x.com/zpravy/status/1234567890123456790",
          "first_link_url" => "https://example.com/clanek",
          "username" => "zpravy",
          "embed_code" => "<p>Podívejte se na tento článek <a href='https://example.com/clanek'>example.com/clanek</a></p>"
        }
      },
      
      short_with_emoji: {
        description: "Short tweet ending with emoji (Tier 1)",
        expected_tier: 1,
        payload: {
          "text" => "Dnes bude krásné počasí ☀️",
          "link_to_tweet" => "https://x.com/pocasi/status/1234567890123456791",
          "first_link_url" => "",
          "username" => "pocasi",
          "embed_code" => "<p>Dnes bude krásné počasí ☀️</p>"
        }
      },
      
      simple_retweet: {
        description: "Simple retweet (Tier 2 - IFTTT truncates RTs)",
        expected_tier: 2,
        payload: {
          "text" => "RT @original_user: Toto je původní tweet, který někdo retweetnul.",
          "link_to_tweet" => "https://x.com/retweeter/status/1234567890123456792",
          "first_link_url" => "",
          "username" => "retweeter",
          "embed_code" => "<p>RT @original_user: Toto je původní tweet.</p>"
        }
      },
      
      short_reply: {
        description: "Short reply (Tier 1)",
        expected_tier: 1,
        payload: {
          "text" => "@someone Díky za info!",
          "link_to_tweet" => "https://x.com/replier/status/1234567890123456793",
          "first_link_url" => "",
          "username" => "replier",
          "embed_code" => "<p>@someone Díky za info!</p>"
        }
      },
      
      short_quote: {
        description: "Short quote tweet (Tier 2 - first_link is status URL)",
        expected_tier: 2,
        payload: {
          "text" => "Tohle je důležité 👇",
          "link_to_tweet" => "https://x.com/quoter/status/1234567890123456794",
          "first_link_url" => "https://x.com/original/status/9876543210987654321",
          "username" => "quoter",
          "embed_code" => "<p>Tohle je důležité 👇</p>"
        }
      },
      
      # Tier 2: Truncated tweets (SHOULD trigger Nitter fetch)
      truncated_ellipsis: {
        description: "Tweet truncated with ellipsis (Tier 2)",
        expected_tier: 2,
        payload: {
          "text" => "Toto je velmi dlouhý tweet, který obsahuje spoustu informací o aktuální situaci ve světě a IFTTT ho musel zkrátit protože překročil limit a proto končí…",
          "link_to_tweet" => "https://x.com/longtweet/status/1234567890123456795",
          "first_link_url" => "",
          "username" => "longtweet",
          "embed_code" => "<p>Toto je velmi dlouhý tweet...</p>"
        }
      },
      
      truncated_url: {
        description: "Tweet with truncated URL (Tier 2)",
        expected_tier: 2,
        payload: {
          "text" => "Přečtěte si náš nový článek na https://example.com/very-long-path/to-article/with-many-segments/that-gets-truncated…",
          "link_to_tweet" => "https://x.com/news/status/1234567890123456796",
          "first_link_url" => "",
          "username" => "news",
          "embed_code" => "<p>Přečtěte si náš nový článek</p>"
        }
      },
      
      long_no_terminator: {
        description: "Long tweet (>=257 chars) without natural terminator (Tier 2)",
        expected_tier: 2,
        payload: {
          "text" => "A" * 260 + " pokračování textu bez tečky na konci",
          "link_to_tweet" => "https://x.com/verbose/status/1234567890123456797",
          "first_link_url" => "",
          "username" => "verbose",
          "embed_code" => "<p>#{"A" * 260} pokračování</p>"
        }
      },
      
      long_with_terminator: {
        description: "Long tweet (>=257 chars) WITH natural terminator (Tier 1)",
        expected_tier: 1,
        payload: {
          "text" => "A" * 250 + " a toto je konec věty s tečkou.",
          "link_to_tweet" => "https://x.com/proper/status/1234567890123456798",
          "first_link_url" => "",
          "username" => "proper",
          "embed_code" => "<p>#{"A" * 250} konec.</p>"
        }
      },
      
      # Edge cases
      edge_256_chars: {
        description: "Exactly 256 chars (just under threshold, Tier 1)",
        expected_tier: 1,
        payload: {
          "text" => "X" * 256,
          "link_to_tweet" => "https://x.com/edge/status/1234567890123456799",
          "first_link_url" => "",
          "username" => "edge",
          "embed_code" => "<p>#{"X" * 256}</p>"
        }
      },
      
      edge_257_chars_with_period: {
        description: "Exactly 257 chars ending with period (Tier 1)",
        expected_tier: 1,
        payload: {
          "text" => "X" * 256 + ".",
          "link_to_tweet" => "https://x.com/edge2/status/1234567890123456800",
          "first_link_url" => "",
          "username" => "edge2",
          "embed_code" => "<p>#{"X" * 256}.</p>"
        }
      },
      
      edge_257_chars_no_terminator: {
        description: "Exactly 257 chars without terminator (Tier 2)",
        expected_tier: 2,
        payload: {
          "text" => "X" * 257,
          "link_to_tweet" => "https://x.com/edge3/status/1234567890123456801",
          "first_link_url" => "",
          "username" => "edge3",
          "embed_code" => "<p>#{"X" * 257}</p>"
        }
      },
      
      triple_dot: {
        description: "Tweet with ... (three dots, Tier 2)",
        expected_tier: 2,
        payload: {
          "text" => "Zpráva pokračuje...",
          "link_to_tweet" => "https://x.com/dots/status/1234567890123456802",
          "first_link_url" => "",
          "username" => "dots",
          "embed_code" => "<p>Zpráva pokračuje...</p>"
        }
      },
      
      # Real-world examples
      real_chmu_vystraha: {
        description: "ČHMÚ výstraha (real format, Tier 1)",
        expected_tier: 1,
        payload: {
          "text" => "⚠️ VÝSTRAHA: Silný vítr, Jihomoravský kraj, platnost od 18:00 do 06:00. Očekáváme nárazy větru 70-90 km/h.",
          "link_to_tweet" => "https://x.com/CHMUCHMI/status/2014226269169168775",
          "first_link_url" => "https://pbs.twimg.com/media/example.jpg",
          "username" => "CHMUCHMI",
          "embed_code" => "<p>⚠️ VÝSTRAHA: Silný vítr...</p>"
        }
      },
      
      real_chmu_pocasi_truncated: {
        description: "ČHMÚ počasí - ZKRÁCENÝ s t.co na konci (Tier 2)",
        expected_tier: 2,
        payload: {
          "text" => "🌚V pátek i během víkendu musíme počítat spíše s podmračenou oblohou, slunečno bude hlavně na Šumavě v pátek a v sobotu. Slabé sněžení nebo mrholení se objeví jen výjimečně, víc ho může být na Moravě a ve Slezsku a může být i mrznoucí. Až v neděli později večer začne nejdřív https://t.co/AnS1WCAT8v",
          "link_to_tweet" => "https://twitter.com/CHMUCHMI/status/2014348309213687886",
          "first_link_url" => "https://x.com/CHMUCHMI/status/2014348309213687886/photo/1",
          "username" => "CHMUCHMI",
          "embed_code" => "<p>🌚V pátek i během víkendu...</p>"
        }
      },
      
      real_ruske_ztraty_truncated: {
        description: "Ruské ztráty - ZKRÁCENÝ bez ellipsis (Tier 2)",
        expected_tier: 2,
        payload: {
          "text" => "Ruské ztráty: - 1 230 810 vojáků (+1 070) - 11 596 tanků (+9) - 23 943 obrněnců (+5) - 36 516 kusů dělostřelectva (+53) - 1 623 kusů raketometů (+2) - 1 282 kusů PVO (+3) - 434 letadel (+0) - 347 vrtulníků (+0) - 112 828 dronů (+669) - 4 190 raket s plochou dráhou letu (+0) - 28",
          "link_to_tweet" => "https://twitter.com/andrewofpolesia/status/2014238941935780114",
          "first_link_url" => "",
          "username" => "andrewofpolesia",
          "embed_code" => "<p>Ruské ztráty...</p>"
        }
      },
      
      real_reply: {
        description: "Reply tweet with photo (real format, Tier 2)",
        expected_tier: 2,
        payload: {
          "text" => "@Gabana Mazačka příspěvků @DolphSegal MAGA https://t.co/m5LbEHKjvD",
          "link_to_tweet" => "https://twitter.com/1250cc03004c44e/status/2014357252170260611",
          "first_link_url" => "https://x.com/1250cc03004c44e/status/2014357252170260611/photo/1",
          "username" => "1250cc03004c44e",
          "embed_code" => "<p>@Gabana Mazačka příspěvků...</p>"
        }
      },
      
      real_quote: {
        description: "Quote tweet (real format, Tier 2 - first_link is status URL)",
        expected_tier: 2,
        payload: {
          "text" => "Dropshipping was just made even easier, humans are becoming less and less relevant https://t.co/DuI0Dw7TmY",
          "link_to_tweet" => "https://twitter.com/historyinmemes/status/2014354387104125182",
          "first_link_url" => "https://twitter.com/eshamanideep/status/2014353271331434938",
          "username" => "historyinmemes",
          "embed_code" => "<p>Dropshipping was just made even easier...</p>"
        }
      },
      
      real_retweet: {
        description: "Retweet (real format, Tier 2 - IFTTT truncates RTs)",
        expected_tier: 2,
        payload: {
          "text" => "RT @Kolarovichrabe1: Dospělí lide, kteří siří tyhle AI sracky a ještě s takovým komentářem by neměli mít volební pravo. Change my mind.",
          "link_to_tweet" => "https://twitter.com/jietienming/status/2014334120382390703",
          "first_link_url" => "",
          "username" => "jietienming",
          "embed_code" => "<p>RT @Kolarovichrabe1: Dospělí lide...</p>"
        }
      },
      
      real_ct24_breaking: {
        description: "ČT24 breaking news (real format, likely Tier 1)",
        expected_tier: 1,
        payload: {
          "text" => "PRÁVĚ: Vláda schválila nový balíček opatření. Více informací v 18:00 na ČT24.",
          "link_to_tweet" => "https://x.com/ct24zive/status/1234567890123456804",
          "first_link_url" => "",
          "username" => "ct24zive",
          "embed_code" => "<p>PRÁVĚ: Vláda schválila...</p>"
        }
      }
    }.freeze

    def initialize
      @adapter = Adapters::TwitterNitterAdapter.new(
        nitter_instance: ENV['NITTER_INSTANCE'],
        use_nitter_fallback: false # Don't actually fetch from Nitter in tests
      )
    end

    # ===========================================
    # Test Methods
    # ===========================================

    # Test single payload
    def test_payload(payload, description: nil)
      puts "\n#{"=" * 60}"
      puts "Testing: #{description || 'Custom payload'}"
      puts "=" * 60
      
      # Parse and validate
      parsed = @adapter.parse_ifttt_payload(payload)
      unless parsed
        puts "❌ Failed to parse payload"
        return { success: false, error: "Parse failed" }
      end
      
      puts "\n📥 Input:"
      puts "   Username: @#{parsed[:username]}"
      puts "   Post ID:  #{parsed[:post_id]}"
      puts "   Text:     #{truncate_for_display(parsed[:text], 80)}"
      puts "   Length:   #{parsed[:text]&.length || 0} chars"
      
      # Check for t.co links
      tco_count = parsed[:text]&.scan(%r{https?://t\.co/\S+})&.count || 0
      puts "   t.co links: #{tco_count}" if tco_count > 0
      
      # Determine tier
      tier = @adapter.determine_tier(parsed)
      truncated = @adapter.likely_truncated?(parsed[:text])
      
      puts "\n🔍 Analysis:"
      puts "   Truncated: #{truncated ? '✅ YES' : '❌ NO'}"
      puts "   Tier:      #{tier}"
      
      # Detect post type
      post_type = @adapter.detect_post_type(parsed[:text], parsed[:first_link_url])
      puts "\n📝 Post Type:"
      puts "   Repost:  #{post_type[:is_repost] ? "✅ (by @#{post_type[:reposted_by]})" : '❌'}"
      puts "   Reply:   #{post_type[:is_reply] ? '✅' : '❌'}"
      puts "   Quote:   #{post_type[:is_quote] ? "✅ (#{post_type[:quoted_url]})" : '❌'}"
      
      {
        success: true,
        tier: tier,
        truncated: truncated,
        post_type: post_type,
        parsed: parsed
      }
    end

    # Test all sample payloads
    def test_all_samples
      puts "\n" + "=" * 70
      puts "TESTING ALL SAMPLE PAYLOADS"
      puts "=" * 70
      
      results = { passed: 0, failed: 0, details: [] }
      
      SAMPLE_PAYLOADS.each do |key, sample|
        result = test_payload(sample[:payload], description: sample[:description])
        
        expected = sample[:expected_tier]
        actual = result[:tier]
        passed = expected == actual
        
        puts "\n   Expected Tier: #{expected}"
        puts "   Actual Tier:   #{actual}"
        puts "   Result:        #{passed ? '✅ PASS' : '❌ FAIL'}"
        
        if passed
          results[:passed] += 1
        else
          results[:failed] += 1
        end
        
        results[:details] << {
          key: key,
          description: sample[:description],
          expected: expected,
          actual: actual,
          passed: passed
        }
      end
      
      print_summary(results)
      results
    end

    # Analyze tier distribution
    def analyze_distribution
      puts "\n" + "=" * 70
      puts "TIER DISTRIBUTION ANALYSIS"
      puts "=" * 70
      
      tier1_count = 0
      tier2_count = 0
      
      SAMPLE_PAYLOADS.each do |_key, sample|
        tier = sample[:expected_tier]
        tier1_count += 1 if tier == 1
        tier2_count += 1 if tier == 2
      end
      
      total = tier1_count + tier2_count
      
      puts "\nDistribution of #{total} sample payloads:"
      puts "  Tier 1 (IFTTT direct): #{tier1_count} (#{(tier1_count.to_f / total * 100).round(1)}%)"
      puts "  Tier 2 (Nitter fetch): #{tier2_count} (#{(tier2_count.to_f / total * 100).round(1)}%)"
      puts "\nIn production, expect ~80% Tier 1, ~20% Tier 2"
    end

    # Send payload to webhook server
    def send_to_webhook(payload, url)
      uri = URI.parse(url)
      
      puts "\n📤 Sending to #{url}..."
      
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      
      request = Net::HTTP::Post.new(uri.path)
      request['Content-Type'] = 'application/json'
      request.body = payload.is_a?(String) ? payload : JSON.generate(payload)
      
      response = http.request(request)
      
      puts "   Status: #{response.code}"
      puts "   Body:   #{response.body}"
      
      {
        success: response.code.to_i == 200,
        status: response.code.to_i,
        body: response.body
      }
    rescue StandardError => e
      puts "❌ Request failed: #{e.message}"
      { success: false, error: e.message }
    end

    private

    def print_summary(results)
      puts "\n" + "=" * 70
      puts "SUMMARY"
      puts "=" * 70
      puts "Passed: #{results[:passed]}"
      puts "Failed: #{results[:failed]}"
      puts "Total:  #{results[:passed] + results[:failed]}"
      
      if results[:failed] > 0
        puts "\nFailed tests:"
        results[:details].select { |d| !d[:passed] }.each do |detail|
          puts "  - #{detail[:key]}: expected Tier #{detail[:expected]}, got Tier #{detail[:actual]}"
        end
      end
    end

    def truncate_for_display(text, max_length)
      return "(empty)" if text.nil? || text.empty?
      text.length > max_length ? "#{text[0, max_length]}..." : text
    end
  end
end

# ===========================================
# CLI
# ===========================================

if __FILE__ == $PROGRAM_NAME
  options = {}
  
  OptionParser.new do |opts|
    opts.banner = "Usage: #{$PROGRAM_NAME} [options]"
    
    opts.on('-p', '--payload JSON', 'Test single JSON payload') do |json|
      options[:payload] = JSON.parse(json)
    end
    
    opts.on('-f', '--file PATH', 'Test payload from JSON file') do |path|
      options[:payload] = JSON.parse(File.read(path))
    end
    
    opts.on('-s', '--samples', 'Test all sample payloads') do
      options[:samples] = true
    end
    
    opts.on('-a', '--analyze', 'Analyze tier distribution') do
      options[:analyze] = true
    end
    
    opts.on('--send', 'Send to webhook server') do
      options[:send] = true
    end
    
    opts.on('-u', '--url URL', 'Webhook URL (default: http://localhost:8089/api/ifttt/twitter)') do |url|
      options[:url] = url
    end
    
    opts.on('--sample NAME', 'Test specific sample by name') do |name|
      options[:sample_name] = name.to_sym
    end
    
    opts.on('-l', '--list', 'List available sample names') do
      options[:list] = true
    end
    
    opts.on('-h', '--help', 'Show help') do
      puts opts
      exit
    end
  end.parse!
  
  tester = Testing::IftttHybridTester.new
  
  if options[:list]
    puts "Available samples:"
    Testing::IftttHybridTester::SAMPLE_PAYLOADS.each do |key, sample|
      puts "  #{key}: #{sample[:description]}"
    end
    exit
  end
  
  if options[:sample_name]
    sample = Testing::IftttHybridTester::SAMPLE_PAYLOADS[options[:sample_name]]
    if sample
      tester.test_payload(sample[:payload], description: sample[:description])
    else
      puts "Unknown sample: #{options[:sample_name]}"
      puts "Use --list to see available samples"
      exit 1
    end
  elsif options[:payload]
    result = tester.test_payload(options[:payload])
    if options[:send]
      url = options[:url] || 'http://localhost:8089/api/ifttt/twitter'
      tester.send_to_webhook(options[:payload], url)
    end
  elsif options[:samples]
    tester.test_all_samples
  elsif options[:analyze]
    tester.analyze_distribution
  else
    # Default: run all samples
    tester.test_all_samples
    tester.analyze_distribution
  end
end
