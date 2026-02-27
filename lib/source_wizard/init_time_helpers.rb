# frozen_string_literal: true

require 'time'
require_relative '../support/ui_helpers'

module SourceWizard
  # Shared init-time wizard for source_state initialization.
  # Used by SourceGenerator (create_source.rb) and SourceManager (manage_source.rb).
  module InitTimeHelpers
    include Support::UiHelpers

    INIT_TIME_OPTIONS = {
      'now'    => { label: 'Nyní (nezpracuje staré posty)', offset: 0 },
      '1h'     => { label: 'Před 1 hodinou',                offset: 3600 },
      '6h'     => { label: 'Před 6 hodinami',               offset: 6 * 3600 },
      '24h'    => { label: 'Před 24 hodinami',              offset: 24 * 3600 },
      'custom' => { label: 'Vlastní datum/čas',             offset: nil }
    }.freeze

    # Interaktivně zjistí init čas pro source_state.last_check.
    # @return [Time]
    def ask_init_time
      init_labels = INIT_TIME_OPTIONS.values.map { |opt| opt[:label] }
      default_label = init_labels.first

      choice = ask_choice('Od kdy zpracovávat příspěvky', init_labels, default: default_label)
      key = INIT_TIME_OPTIONS.keys[init_labels.index(choice)]

      if key == 'custom'
        puts '  Formát: YYYY-MM-DD HH:MM (např. 2026-01-30 14:00)'
        custom = ask('Datum a čas', required: true)
        begin
          Time.parse(custom)
        rescue ArgumentError
          puts "  ⚠️  Neplatný formát, použiji 'nyní'"
          Time.now
        end
      else
        Time.now - INIT_TIME_OPTIONS[key][:offset]
      end
    end
  end
end
