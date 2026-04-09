#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
# Test Suite: Friendly Follow (#FF)
# ============================================================
#
# Covers: rotation logic, formatting, state serialization.
# No network, no DB — pure unit tests.
#
# Usage:
#   ruby test/test_friendly_follow.rb
#   ruby test/test_friendly_follow.rb --verbose
#
# ============================================================

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
$verbose = ARGV.include?('--verbose')

require 'tmpdir'
require 'json'
require 'yaml'

require 'ff/friendly_follow'

# Stub MastodonPublisher after all requires to override the real implementation
module Publishers
  class MastodonPublisher
    def initialize(**); end
    def publish(text, **); { 'url' => 'https://example.com/1', 'id' => '1' }; end
  end
end

puts '=' * 60
puts '  Friendly Follow Tests'
puts '=' * 60
puts

$passed = 0
$failed = 0

def test(name, expected, actual)
  if expected == actual
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Expected: #{expected.inspect}"
    puts "    Actual:   #{actual.inspect}"
    $failed += 1
  end
end

def test_includes(name, substring, actual)
  if actual.to_s.include?(substring)
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Expected to include: #{substring.inspect}"
    puts "    Actual (excerpt): #{actual.to_s[0, 400].inspect}"
    $failed += 1
  end
end

def test_excludes(name, substring, actual)
  if !actual.to_s.include?(substring)
    puts "  \e[32m\u2713\e[0m #{name}"
    $passed += 1
  else
    puts "  \e[31m\u2717\e[0m #{name}"
    puts "    Expected NOT to include: #{substring.inspect}"
    puts "    Actual (excerpt): #{actual.to_s[0, 400].inspect}"
    $failed += 1
  end
end

def test_true(name, actual)
  test(name, true, !!actual)
end

def test_false(name, actual)
  test(name, false, !!actual)
end

def section(title)
  puts
  puts "--- #{title} ---"
end

# ============================================================
# Helpers — create a FriendlyFollow instance backed by a temp dir
# ============================================================

SAMPLE_ACCOUNTS_YAML = <<~YAML
  ct24:
    token: "token_ct24"
    description: "ČT24"
  aktualne:
    token: "token_aktualne"
  idnescz:
    token: "token_idnes"
  novinky:
    token: "token_novinky"
  ihned:
    token: "token_ihned"
  betabot:
    token: "token_betabot"
    categories: [test]
YAML

def make_ff(tmpdir, state: nil, extra_options: {})
  config_dir  = File.join(tmpdir, 'config')
  state_path  = File.join(tmpdir, 'data', 'ff_rotation.json')

  FileUtils.mkdir_p(config_dir)
  File.write(File.join(config_dir, 'mastodon_accounts.yml'), SAMPLE_ACCOUNTS_YAML)

  if state
    FileUtils.mkdir_p(File.join(tmpdir, 'data'))
    File.write(state_path, JSON.pretty_generate(state))
  end

  FF::FriendlyFollow.new(
    config_dir:   config_dir,
    state_path:   state_path,
    instance_url: 'https://zpravobot.news',
    access_token: 'token_zpravobot',
    dry_run:      true,
    **extra_options
  )
end

def load_state(tmpdir)
  path = File.join(tmpdir, 'data', 'ff_rotation.json')
  return nil unless File.exist?(path)
  JSON.parse(File.read(path))
end

# ============================================================
# Access private methods for unit testing rotation logic
# ============================================================

class FF::FriendlyFollow
  public :load_or_init_rotation, :load_accounts_config, :read_state,
         :save_state, :eligible_ids, :truncate_bio, :build_post_text,
         :format_post
end

# ============================================================
# Section: Czech dates
# ============================================================
section 'Czech dates & days'

ff_date = FF::FriendlyFollow.new(
  config_dir: '.', state_path: '/dev/null',
  instance_url: 'https://zpravobot.news', access_token: 'x'
)

test 'format_czech_date — 8. dubna 2026',
     '8. dubna 2026',
     ff_date.format_czech_date(Time.new(2026, 4, 8))

test 'format_czech_date — 1. ledna 2025',
     '1. ledna 2025',
     ff_date.format_czech_date(Time.new(2025, 1, 1))

test 'format_czech_date — 31. prosince 2026',
     '31. prosince 2026',
     ff_date.format_czech_date(Time.new(2026, 12, 31))

# DAYS_CS index: 0=neděle, 1=pondělí, 2=úterý, 3=středa, 4=čtvrtek, 5=pátek, 6=sobota
[
  [Time.new(2026, 4, 5), 'neděli'],
  [Time.new(2026, 4, 6), 'pondělí'],
  [Time.new(2026, 4, 7), 'úterý'],
  [Time.new(2026, 4, 8), 'středu'],
  [Time.new(2026, 4, 9), 'čtvrtek'],
  [Time.new(2026, 4, 10), 'pátek'],
  [Time.new(2026, 4, 11), 'sobotu']
].each do |t, day|
  test "day name — #{day}",
       "tip na #{day}",
       "tip na #{FF::FriendlyFollow::DAYS_CS[t.wday]}"
end

# All 12 months
expected_months = %w[
  _ ledna února března dubna května června
  července srpna září října listopadu prosince
]
test 'MONTHS_CS has 13 entries (index 1-12)', 13, FF::FriendlyFollow::MONTHS_CS.size
expected_months.each_with_index do |m, i|
  next if i == 0
  test "month #{i} = #{m}", m, FF::FriendlyFollow::MONTHS_CS[i]
end

# ============================================================
# Section: Bio truncation
# ============================================================
section 'Bio truncation'

ff_trunc = FF::FriendlyFollow.new(
  config_dir: '.', state_path: '/dev/null',
  instance_url: 'https://zpravobot.news', access_token: 'x'
)

short_bio = 'Krátké bio'
test 'short bio unchanged', short_bio, ff_trunc.truncate_bio(short_bio)

long_bio  = 'a' * 400 + ' ' + 'b' * 200
truncated = ff_trunc.truncate_bio(long_bio)
test_true  'truncated bio ≤ 500 chars',    truncated.length <= 500
test_true  'truncated bio ends with …',    truncated.end_with?('…')
test_false 'truncated bio does NOT cut mid-word', truncated.include?('b')

exact_500 = 'x ' * 250  # 500 chars
test 'bio of exactly 500 chars unchanged', exact_500, ff_trunc.truncate_bio(exact_500)

bio_501 = 'x ' * 250 + 'y'  # 501 chars
t501 = ff_trunc.truncate_bio(bio_501)
test_true 'bio of 501 chars gets truncated', t501.length <= 500

# Custom max
test 'custom max 20 chars', true, ff_trunc.truncate_bio('hello world foo bar baz qux', 20).length <= 20

# ============================================================
# Section: Rotation — new cycle
# ============================================================
section 'Rotation — new cycle'

Dir.mktmpdir do |tmpdir|
  ff = make_ff(tmpdir)
  accounts = ff.load_accounts_config
  state    = ff.load_or_init_rotation(accounts)

  test 'new cycle: cycle = 1', 1, state[:cycle]
  test 'new cycle: promoted = []', [], state[:promoted]
  test_false 'new cycle: remaining not empty', state[:remaining].empty?
  test_false 'new cycle: betabot excluded', state[:remaining].include?('betabot')
  test 'new cycle: all eligible in remaining', 5, state[:remaining].size  # 5 accounts (ct24, aktualne, idnescz, novinky, ihned)
end

# ============================================================
# Section: Rotation — selecting 3 accounts
# ============================================================
section 'Rotation — select and move'

Dir.mktmpdir do |tmpdir|
  ff = make_ff(tmpdir)
  accounts = ff.load_accounts_config

  # Simulate run: load state, pick 3
  state        = ff.load_or_init_rotation(accounts)
  remaining_before = state[:remaining].dup
  selected     = state[:remaining].sample(3)
  state[:remaining] -= selected
  state[:promoted]  += selected

  test 'selected count = 3',      3,        selected.size
  test 'remaining shrunk by 3',   remaining_before.size - 3, state[:remaining].size
  test 'promoted has 3',          3,        state[:promoted].size
  test_false 'selected not in remaining', (selected & state[:remaining]).any?
  test 'selected in promoted', selected, state[:promoted]
end

# ============================================================
# Section: Rotation — less than 3 remaining
# ============================================================
section 'Rotation — less than 3 remaining'

Dir.mktmpdir do |tmpdir|
  ff = make_ff(tmpdir, state: {
    'cycle'     => 2,
    'promoted'  => %w[ct24 aktualne idnescz],
    'remaining' => %w[novinky]
  })
  accounts = ff.load_accounts_config
  state    = ff.load_or_init_rotation(accounts)

  test 'stays in cycle 2',        2, state[:cycle]
  test 'remaining has 1 + ihned', 2, state[:remaining].size  # novinky + ihned (new account)
end

# ============================================================
# Section: Rotation — cycle reset after exhaustion
# ============================================================
section 'Rotation — cycle reset'

Dir.mktmpdir do |tmpdir|
  ff = make_ff(tmpdir, state: {
    'cycle'     => 3,
    'promoted'  => %w[ct24 aktualne idnescz novinky ihned],
    'remaining' => []
  })
  accounts = ff.load_accounts_config
  state    = ff.load_or_init_rotation(accounts)

  test 'cycle incremented to 4',  4,    state[:cycle]
  test 'promoted reset to []',    [],   state[:promoted]
  test 'remaining filled again',  5,    state[:remaining].size
  test_false 'betabot still excluded', state[:remaining].include?('betabot')
end

# ============================================================
# Section: Rotation — new accounts injected mid-cycle
# ============================================================
section 'Rotation — new accounts injected mid-cycle'

Dir.mktmpdir do |tmpdir|
  # State only knows about 3 accounts; YAML has 5 eligible → 2 new ones
  ff = make_ff(tmpdir, state: {
    'cycle'     => 1,
    'promoted'  => %w[ct24],
    'remaining' => %w[aktualne idnescz]
  })
  accounts = ff.load_accounts_config
  state    = ff.load_or_init_rotation(accounts)

  # novinky and ihned are new; should be added to remaining
  test 'cycle unchanged',     1, state[:cycle]
  test 'remaining = 4',       4, state[:remaining].size
  test_true  'novinky added', state[:remaining].include?('novinky')
  test_true  'ihned added',   state[:remaining].include?('ihned')
  test_false 'betabot not added', state[:remaining].include?('betabot')
end

# ============================================================
# Section: Rotation — betabot always excluded
# ============================================================
section 'Rotation — betabot excluded'

Dir.mktmpdir do |tmpdir|
  ff       = make_ff(tmpdir)
  accounts = ff.load_accounts_config
  state    = ff.load_or_init_rotation(accounts)

  test_false 'betabot not in remaining', state[:remaining].include?('betabot')
  test_false 'betabot not in promoted',  state[:promoted].include?('betabot')
  test_true  'eligible_ids excludes betabot', !ff.eligible_ids(accounts).include?('betabot')
end

# ============================================================
# Section: State serialization
# ============================================================
section 'State serialization'

Dir.mktmpdir do |tmpdir|
  ff         = make_ff(tmpdir)
  state_path = File.join(tmpdir, 'data', 'ff_rotation.json')
  state_in   = { cycle: 5, promoted: %w[ct24 aktualne], remaining: %w[idnescz novinky ihned] }

  FileUtils.mkdir_p(File.dirname(state_path))
  ff.save_state(state_in)

  test_true 'state file exists', File.exist?(state_path)

  state_out = ff.read_state
  test 'cycle round-trips',     5,                        state_out[:cycle]
  test 'promoted round-trips',  %w[ct24 aktualne],        state_out[:promoted]
  test 'remaining round-trips', %w[idnescz novinky ihned], state_out[:remaining]
end

# Missing state file → nil
Dir.mktmpdir do |tmpdir|
  ff = make_ff(tmpdir)
  test 'missing state file → nil', nil, ff.read_state
end

# Corrupt JSON → nil
Dir.mktmpdir do |tmpdir|
  ff = make_ff(tmpdir)
  FileUtils.mkdir_p(File.join(tmpdir, 'data'))
  File.write(File.join(tmpdir, 'data', 'ff_rotation.json'), 'NOT JSON {{{')
  test 'corrupt JSON → nil', nil, ff.read_state
end

# ============================================================
# Section: Post formatting
# ============================================================
section 'Post formatting'

accounts_data = [
  { id: 'ct24',     display_name: 'ČT24',       bio: 'Zpravodajský kanál České televize.', instance_host: 'zpravobot.news' },
  { id: 'aktualne', display_name: 'Aktuálně.cz', bio: 'Nezávislý zpravodajský server.',     instance_host: 'zpravobot.news' },
  { id: 'idnescz',  display_name: 'iDNES.cz',   bio: nil,                                   instance_host: 'zpravobot.news' }
]

header = '#FF 🇨🇿 tip na středu, 8. dubna 2026:'
ff_fmt = FF::FriendlyFollow.new(
  config_dir: '.', state_path: '/dev/null',
  instance_url: 'https://zpravobot.news', access_token: 'x'
)
post = ff_fmt.build_post_text(accounts_data, header, 'zpravobot.news')

test_includes 'header #FF 🇨🇿',              '#FF 🇨🇿',                  post
test_includes 'header day/date',              'tip na středu, 8. dubna 2026:', post
test_includes 'ct24 handle',                  '@ct24@zpravobot.news',     post
test_includes 'ct24 display name',            'ČT24',                     post
test_includes 'ct24 bio',                     'Zpravodajský kanál České televize.', post
test_includes 'aktualne handle',              '@aktualne@zpravobot.news', post
test_includes 'footer #zpravobot',            '#zpravobot',               post
test_includes 'footer #ffcz',                 '#ffcz',                    post
test_includes 'em-dash separator',            ' — ',                      post

# Empty bio → no blank bio line (just handle line)
idnes_block_start = post.index('iDNES.cz')
idnes_block       = post[idnes_block_start..]
test_excludes 'empty bio → no extra blank line before footer',
              "iDNES.cz — @idnescz@zpravobot.news\n\n\n",
              post

# Footer is at the end
test_true 'footer at end', post.strip.end_with?('#zpravobot #ffcz')

# Post length ≤ 2500
test_true 'post ≤ 2500 chars', post.length <= 2500

# ============================================================
# Section: format_post with long bios (auto-trim)
# ============================================================
section 'format_post — long bio trimming'

long_bio = ('palavra ' * 100).strip  # ~700 chars

accounts_long = [
  { id: 'ct24',     display_name: 'ČT24',       bio: long_bio, instance_host: 'zpravobot.news' },
  { id: 'aktualne', display_name: 'Aktuálně.cz', bio: long_bio, instance_host: 'zpravobot.news' },
  { id: 'idnescz',  display_name: 'iDNES.cz',   bio: long_bio, instance_host: 'zpravobot.news' }
]

time_wed = Time.new(2026, 4, 8, 12, 0, 0)
post_long = ff_fmt.format_post(accounts_long, time_wed)
test_true  'long bio post ≤ 2500 chars', post_long.length <= 2500
test_includes 'long bio post has header', '#FF 🇨🇿', post_long
test_includes 'long bio post has footer', '#ffcz',   post_long

# ============================================================
# Section: format_post with all 7 day names
# ============================================================
section 'format_post — all day names'

base_time = Time.new(2026, 4, 5)  # Sunday
sample_acc = [{ id: 'ct24', display_name: 'ČT24', bio: nil, instance_host: 'zpravobot.news' }]
expected_days = %w[neděli pondělí úterý středu čtvrtek pátek sobotu]

7.times do |wday|
  t    = base_time + wday * 86400
  text = ff_fmt.format_post(sample_acc, t)
  test_includes "day #{wday} = #{expected_days[wday]}", "tip na #{expected_days[wday]}", text
end

# ============================================================
# Section: run — dry-run integration
# ============================================================
section 'run — dry-run integration'

Dir.mktmpdir do |tmpdir|
  ff     = make_ff(tmpdir)
  result = ff.run

  test_false 'dry-run: posted = false',    result[:posted]
  test_true  'dry-run: accounts present',  result[:accounts].is_a?(Array) && !result[:accounts].empty?
  test_true  'dry-run: post_text present', result[:post_text].is_a?(String) && !result[:post_text].empty?
  test_true  'dry-run: ≤ 3 accounts promoted', result[:accounts].size <= 3
  test_false 'dry-run: betabot not promoted',  result[:accounts].include?('betabot')
  test_true  'dry-run: state NOT saved',   !File.exist?(File.join(tmpdir, 'data', 'ff_rotation.json'))
end

# ============================================================
# Section: run — state saved after publish (simulated)
# ============================================================
section 'run — state saved after publish'

Dir.mktmpdir do |tmpdir|
  # Non-dry-run; MastodonPublisher is stubbed at top
  ff = FF::FriendlyFollow.new(
    config_dir:   File.join(tmpdir, 'config'),
    state_path:   File.join(tmpdir, 'data', 'ff_rotation.json'),
    instance_url: 'https://zpravobot.news',
    access_token: 'token',
    dry_run:      false
  )

  FileUtils.mkdir_p(File.join(tmpdir, 'config'))
  File.write(File.join(tmpdir, 'config', 'mastodon_accounts.yml'), SAMPLE_ACCOUNTS_YAML)

  # Stub fetch_account_profile to avoid network
  ff.define_singleton_method(:fetch_account_profile) do |id, _creds|
    { display_name: id.upcase, bio: 'Test bio.' }
  end

  result = ff.run

  test_true  'publish: posted = true',     result[:posted]
  test_true  'publish: url returned',      result[:url].to_s.length > 0
  test_true  'publish: state file saved',  File.exist?(File.join(tmpdir, 'data', 'ff_rotation.json'))

  saved = JSON.parse(File.read(File.join(tmpdir, 'data', 'ff_rotation.json')))
  test_true  'saved: promoted not empty',  saved['promoted'].is_a?(Array) && !saved['promoted'].empty?
  test_true  'saved: remaining is array',  saved['remaining'].is_a?(Array)
  test_true  'saved: cycle = 1',           saved['cycle'] == 1
end

# ============================================================
# Results
# ============================================================
puts
puts '=' * 60
total = $passed + $failed
puts "  #{$passed}/#{total} tests passed"
puts '=' * 60

exit($failed > 0 ? 1 : 0)
