#!/usr/bin/env ruby
# frozen_string_literal: true

# Test State Repository Classes (Phase 8 — #15)
# Validates that repository source files define the expected methods.
# Uses source code analysis (no PG gem required — offline test).
# Run: ruby test/test_state_repositories.rb
#
# NOTE: Integration tests with PostgreSQL remain in test_state_manager.rb.

puts "=" * 60
puts "State Repository Tests (Phase 8 — #15)"
puts "=" * 60
puts

$passed = 0
$failed = 0

LIB_DIR = File.expand_path('../lib', __dir__)

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

def section(title)
  puts
  puts "--- #{title} ---"
end

# Helper: extract `def method_name` from a file
def extract_public_methods(file_path)
  content = File.read(file_path)
  # Extract method names, skip private/protected sections
  in_private = false
  methods = []
  content.each_line do |line|
    stripped = line.strip
    if stripped == 'private' || stripped == 'protected'
      in_private = true
      next
    end
    # Reset on new class/module (nested classes)
    if stripped.match?(/^\s*(?:class|module)\s/)
      in_private = false
    end
    unless in_private
      if match = stripped.match(/^def\s+(\w+[?!]?)/)
        methods << match[1]
      end
    end
  end
  methods
end

# Helper: check file exists
def file_exists?(path)
  File.exist?(path)
end

# =============================================================================
# 1. Repository files exist
# =============================================================================
section("Repository Files Exist")

files = {
  'database_connection.rb' => "#{LIB_DIR}/state/database_connection.rb",
  'published_posts_repository.rb' => "#{LIB_DIR}/state/published_posts_repository.rb",
  'source_state_repository.rb' => "#{LIB_DIR}/state/source_state_repository.rb",
  'activity_logger.rb' => "#{LIB_DIR}/state/activity_logger.rb",
  'edit_buffer_manager.rb' => "#{LIB_DIR}/state/edit_buffer_manager.rb",
  'state_manager.rb' => "#{LIB_DIR}/state/state_manager.rb",
}

files.each do |name, path|
  test("#{name} exists", true, file_exists?(path))
end

# =============================================================================
# 2. DatabaseConnection methods
# =============================================================================
section("DatabaseConnection: Methods")

dc_methods = extract_public_methods(files['database_connection.rb'])

%w[initialize connect disconnect connected? ensure_connection conn].each do |m|
  test("DatabaseConnection##{m}", true, dc_methods.include?(m))
end

# =============================================================================
# 3. PublishedPostsRepository methods
# =============================================================================
section("PublishedPostsRepository: Methods")

pp_methods = extract_public_methods(files['published_posts_repository.rb'])

%w[published? find_by_platform_uri find_by_post_id find_recent_thread_parent
   mark_published find_mastodon_id_by_platform_uri find_mastodon_id_by_post_id
   recent_published].each do |m|
  test("PublishedPostsRepository##{m}", true, pp_methods.include?(m))
end

# =============================================================================
# 4. SourceStateRepository methods
# =============================================================================
section("SourceStateRepository: Methods")

ss_methods = extract_public_methods(files['source_state_repository.rb'])

%w[get_source_state mark_check_success mark_check_error sources_due_for_check
   reset_daily_counters stats sources_with_errors].each do |m|
  test("SourceStateRepository##{m}", true, ss_methods.include?(m))
end

# =============================================================================
# 5. ActivityLogger methods
# =============================================================================
section("ActivityLogger: Methods")

al_methods = extract_public_methods(files['activity_logger.rb'])

%w[log_activity log_fetch log_publish log_skip log_error_activity
   log_transient_error recent_activity].each do |m|
  test("ActivityLogger##{m}", true, al_methods.include?(m))
end

# =============================================================================
# 6. EditBufferManager methods
# =============================================================================
section("EditBufferManager: Methods")

eb_methods = extract_public_methods(files['edit_buffer_manager.rb'])

%w[add_to_edit_buffer update_edit_buffer_mastodon_id find_by_text_hash
   find_recent_buffer_entries mark_edit_superseded cleanup_edit_buffer
   edit_buffer_stats in_edit_buffer?].each do |m|
  test("EditBufferManager##{m}", true, eb_methods.include?(m))
end

# =============================================================================
# 7. StateManager facade — delegates all methods
# =============================================================================
section("StateManager Facade: Delegates All Methods")

sm_content = File.read(files['state_manager.rb'])

# The facade should have all repository methods
all_delegated = %w[
  connect disconnect connected? ensure_connection
  published? find_by_platform_uri find_by_post_id find_recent_thread_parent
  mark_published find_mastodon_id_by_platform_uri find_mastodon_id_by_post_id
  recent_published
  get_source_state mark_check_success mark_check_error sources_due_for_check
  reset_daily_counters stats sources_with_errors
  log_activity log_fetch log_publish log_skip log_error_activity log_transient_error recent_activity
  add_to_edit_buffer update_edit_buffer_mastodon_id find_by_text_hash
  find_recent_buffer_entries mark_edit_superseded cleanup_edit_buffer
  edit_buffer_stats in_edit_buffer?
]

sm_methods = extract_public_methods(files['state_manager.rb'])

all_delegated.each do |m|
  test("StateManager##{m}", true, sm_methods.include?(m))
end

# =============================================================================
# 8. StateManager requires all repositories
# =============================================================================
section("StateManager: Requires All Repositories")

test("requires database_connection", true, sm_content.include?("require_relative 'database_connection'"))
test("requires published_posts_repository", true, sm_content.include?("require_relative 'published_posts_repository'"))
test("requires source_state_repository", true, sm_content.include?("require_relative 'source_state_repository'"))
test("requires activity_logger", true, sm_content.include?("require_relative 'activity_logger'"))
test("requires edit_buffer_manager", true, sm_content.include?("require_relative 'edit_buffer_manager'"))

# =============================================================================
# 9. StateManager uses delegation pattern
# =============================================================================
section("StateManager: Delegation Pattern")

test("Creates DatabaseConnection", true, sm_content.include?('DatabaseConnection.new'))
test("Creates PublishedPostsRepository", true, sm_content.include?('PublishedPostsRepository.new'))
test("Creates SourceStateRepository", true, sm_content.include?('SourceStateRepository.new'))
test("Creates ActivityLogger", true, sm_content.include?('ActivityLogger.new'))
test("Creates EditBufferManager", true, sm_content.include?('EditBufferManager.new'))

# Verify delegation via instance variables
test("Delegates to @posts", true, sm_content.include?('@posts.'))
test("Delegates to @source_state", true, sm_content.include?('@source_state.'))
test("Delegates to @activity", true, sm_content.include?('@activity.'))
test("Delegates to @edit_buffer", true, sm_content.include?('@edit_buffer.'))
test("Delegates to @db", true, sm_content.include?('@db.'))

# =============================================================================
# Summary
# =============================================================================
puts
puts "=" * 60
puts "Results: #{$passed} passed, #{$failed} failed"
puts "=" * 60

exit($failed == 0 ? 0 : 1)
