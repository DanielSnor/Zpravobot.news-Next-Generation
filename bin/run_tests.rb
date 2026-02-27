#!/usr/bin/env ruby
# frozen_string_literal: true

# bin/run_tests.rb -- ZBNW-NG Test Runner
#
# Usage:
#   ruby bin/run_tests.rb              # Run unit tests (default)
#   ruby bin/run_tests.rb --unit       # Offline unit tests only
#   ruby bin/run_tests.rb --network    # Network-dependent tests
#   ruby bin/run_tests.rb --db         # Database tests (PostgreSQL)
#   ruby bin/run_tests.rb --e2e        # E2E / publish tests (interactive)
#   ruby bin/run_tests.rb --all        # unit + network + db (no interactive)
#   ruby bin/run_tests.rb --everything # Literally everything
#   ruby bin/run_tests.rb --file edit  # Tests matching "edit"
#   ruby bin/run_tests.rb --tag bluesky # Tests tagged "bluesky"
#   ruby bin/run_tests.rb --visual     # Include visual/diagnostic tests
#   ruby bin/run_tests.rb --list       # List tests without running
#   ruby bin/run_tests.rb -h           # Show help

PROJECT_ROOT = File.expand_path('..', __dir__)
$LOAD_PATH.unshift(File.join(PROJECT_ROOT, 'lib'))

require 'optparse'
require 'test_runner/output_parser'
require 'test_runner/report_generator'
require 'test_runner/runner'

options = {
  categories: :default,
  tags: nil,
  file_pattern: nil,
  include_interactive: false,
  skip_visual: true,
  list_only: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby bin/run_tests.rb [options]"
  opts.separator ""
  opts.separator "Category filters (mutually exclusive):"

  opts.on("--unit", "Run offline unit tests (default)") do
    options[:categories] = ['unit']
  end

  opts.on("--network", "Run network-dependent tests") do
    options[:categories] = ['network']
  end

  opts.on("--db", "Run database (PostgreSQL) tests") do
    options[:categories] = ['db']
  end

  opts.on("--e2e", "Run E2E/publish tests (interactive)") do
    options[:categories] = ['e2e']
    options[:include_interactive] = true
  end

  opts.on("--all", "Run unit + network + db (no interactive)") do
    options[:categories] = ['unit', 'network', 'db']
  end

  opts.on("--everything", "Run absolutely everything including interactive") do
    options[:categories] = nil
    options[:include_interactive] = true
    options[:skip_visual] = false
  end

  opts.separator ""
  opts.separator "Fine-grained filters:"

  opts.on("--file PATTERN", "Run tests whose name matches PATTERN") do |p|
    options[:file_pattern] = p
    options[:categories] = nil
  end

  opts.on("--tag TAG", "Run tests with the given tag") do |t|
    options[:tags] ||= []
    options[:tags] << t
    options[:categories] = nil
  end

  opts.on("--visual", "Include visual/diagnostic tests") do
    options[:skip_visual] = false
  end

  opts.separator ""
  opts.separator "Other:"

  opts.on("--list", "List matching tests without running") do
    options[:list_only] = true
  end

  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit
  end
end.parse!

# Default: unit tests only (unless explicitly cleared by --everything, --file, --tag)
options[:categories] = ['unit'] if options[:categories] == :default

catalog_path = File.join(PROJECT_ROOT, 'config', 'test_catalog.yml')

unless File.exist?(catalog_path)
  $stderr.puts "Error: test catalog not found at #{catalog_path}"
  exit 1
end

runner = TestRunner::Runner.new(
  catalog_path: catalog_path,
  project_root: PROJECT_ROOT,
  options: options
)

if options[:list_only]
  runner.list
else
  runner.run
end
