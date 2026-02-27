# frozen_string_literal: true

require_relative '../support/ui_helpers'

class SourceGenerator
  include Support::UiHelpers

  # confirm_save stays here — wizard-specific
  def confirm_save(filepath)
    puts
    ask_yes_no('Uložit konfiguraci?', default: true)
  end
end
