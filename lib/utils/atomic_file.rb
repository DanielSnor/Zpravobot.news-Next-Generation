# frozen_string_literal: true

require 'fileutils'

module Utils
  # Atomic file writes — zapíše data nejdřív do `path.tmp.<pid>`, provede fsync,
  # a pak atomickým `File.rename` nahradí cílový soubor. Pokud proces padne mid-write,
  # cílový soubor zůstává beze změny (buď původní obsah, nebo vůbec neexistuje).
  #
  # Určeno pro JSON state soubory, kde parciálně zapsaný obsah by rozbil next-run parse.
  #
  # Usage:
  #   Utils::AtomicFile.write(path, JSON.pretty_generate(state))
  #   Utils::AtomicFile.write(path, content, encoding: 'UTF-8')
  module AtomicFile
    module_function

    # Atomic write: tmp + fsync + rename.
    # @param path [String] Target file path
    # @param content [String] Content to write
    # @param encoding [String, nil] Optional encoding for File.open mode (default: binary)
    # @return [Integer] Number of bytes written
    def write(path, content, encoding: nil)
      FileUtils.mkdir_p(File.dirname(path))

      tmp_path = "#{path}.tmp.#{Process.pid}"
      mode = encoding ? "w:#{encoding}" : 'wb'

      begin
        bytes = File.open(tmp_path, mode) do |f|
          written = f.write(content)
          f.flush
          f.fsync
          written
        end
        File.rename(tmp_path, path)
        bytes
      rescue StandardError
        File.delete(tmp_path) if File.exist?(tmp_path)
        raise
      end
    end
  end
end
