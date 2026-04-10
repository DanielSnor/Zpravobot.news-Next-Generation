# frozen_string_literal: true

require 'yaml'
require 'time'
require 'set'
require 'net/http'
require 'json'

require_relative '../utils/html_cleaner'

# Detekuje změny v mastodon_accounts.yml oproti uloženému snapshotu
# a publikuje post na @zpravobot@zpravobot.news.
#
# Použití:
#   reporter = Reporting::SourceReporter.new(...)
#   reporter.run          # normální cron běh
#   reporter.init         # vytvoří snapshot bez postování
#
module Reporting
  class SourceReporter
    MASTODON_CHAR_LIMIT = 490  # bezpečnostní rezerva pod 500
    BIO_MAX_CHARS       = 500
    OPEN_TIMEOUT        = 5
    READ_TIMEOUT        = 10

    # Speciální účty vyloučené z reportu
    EXCLUDED_ACCOUNTS = %w[betabot].freeze

    INTROS_NEW_PLURAL = [
      'Od minulého updatu:',
      'Nově:',
      'Tentokrát:',
      'Dnes:'
    ].freeze

    INTROS_NEW_SINGULAR = [
      'Od minulého updatu:',
      'Nově:',
      'Tentokrát:',
      'Dnes:'
    ].freeze

    INTROS_DELETED_PLURAL = [
      'Byli smazáni následující zprávoboti:',
      'Následující zprávoboti byli vyřazeni:',
      'Z nabídky Zpravobotu odchází:',
      'Loučíme se s těmito zpravoboty:'
    ].freeze

    INTROS_DELETED_SINGULAR = [
      'Byl smazán následující zpravobot:',
      'Následující zpravobot byl vyřazen:',
      'Z nabídky Zpravobotu odchází:',
      'Loučíme se s tímto zpravobotem:'
    ].freeze

    # @param accounts_file  [String]  cesta k mastodon_accounts.yml
    # @param snapshot_path  [String]  cesta k data/source_report_snapshot.yml
    # @param publisher      [#publish, nil]  MastodonPublisher instance (nil = dry-run bez publisheru)
    # @param dry_run        [Boolean]
    # @param default_instance [String]  výchozí instance (bez https://)
    def initialize(accounts_file:, snapshot_path:, publisher: nil,
                   dry_run: false, default_instance: 'zpravobot.news')
      @accounts_file     = accounts_file
      @snapshot_path     = snapshot_path
      @publisher         = publisher
      @dry_run           = dry_run
      @default_instance  = default_instance
    end

    # Normální cron běh: detekuje změny, postuje, aktualizuje snapshot.
    def run
      accounts = load_accounts
      snapshot = load_snapshot

      if snapshot.nil?
        warn '[source_report] Snapshot chybí nebo je poškozen — inicializuji bez postování.'
        save_snapshot(accounts.keys)
        return
      end

      current_ids  = Set.new(accounts.keys.reject { |id| EXCLUDED_ACCOUNTS.include?(id) })
      snapshot_ids = Set.new(snapshot.reject  { |id| EXCLUDED_ACCOUNTS.include?(id) })

      new_ids     = (current_ids - snapshot_ids).to_a.sort
      deleted_ids = (snapshot_ids - current_ids).to_a.sort

      if new_ids.empty? && deleted_ids.empty?
        log 'Žádné změny — žádný post.'
        return
      end

      posts_published = 0

      unless new_ids.empty?
        posts = format_new_posts(new_ids, accounts)
        publish_thread(posts)
        posts_published += posts.size
      end

      unless deleted_ids.empty?
        posts = format_deleted_posts(deleted_ids)
        publish_thread(posts)
        posts_published += posts.size
      end

      save_snapshot(accounts.keys) unless @dry_run
      log "Hotovo. Publishováno postů: #{posts_published}."
    end

    # Inicializace: vytvoří snapshot z aktuálního stavu bez postování.
    def init
      accounts = load_accounts
      save_snapshot(accounts.keys)
      log "Snapshot inicializován (#{accounts.size} účtů). Žádný post nebyl publikován."
    end

    # ── Formátování postů ──────────────────────────────────────

    # Vrátí pole postů (stringů) pro nové účty.
    def format_new_posts(new_ids, accounts)
      intro = new_ids.size == 1 ? INTROS_NEW_SINGULAR.sample : INTROS_NEW_PLURAL.sample
      lines = build_new_lines(new_ids, accounts)
      suffix = "\n\n#zpravobot #newbots"
      build_thread(intro, lines, suffix)
    end

    # Vrátí pole postů (stringů) pro smazané účty.
    def format_deleted_posts(deleted_ids)
      intro = deleted_ids.size == 1 ? INTROS_DELETED_SINGULAR.sample : INTROS_DELETED_PLURAL.sample
      lines = deleted_ids.map { |id| "• @#{id}@#{@default_instance}" }
      suffix = "\n\n#zpravobot #deletedbots"
      build_thread(intro, lines, suffix)
    end

    # ── Snapshot ──────────────────────────────────────────────

    def load_snapshot
      return nil unless File.exist?(@snapshot_path)

      data = YAML.safe_load(File.read(@snapshot_path, encoding: 'UTF-8'), permitted_classes: [Symbol])
      return nil unless data.is_a?(Hash) && data['accounts'].is_a?(Array)

      data['accounts']
    rescue StandardError => e
      warn "[source_report] Chyba při načítání snapshotu: #{e.message}"
      nil
    end

    def save_snapshot(account_ids)
      return if @dry_run

      dir = File.dirname(@snapshot_path)
      require 'fileutils'
      FileUtils.mkdir_p(dir)

      content = "# Automaticky generováno source_report.rb\n" \
                "# Neměnit ručně!\n" \
                "last_run: \"#{Time.now.iso8601}\"\n" \
                "accounts:\n" +
                account_ids.sort.map { |id| "  - #{id}\n" }.join
      File.write(@snapshot_path, content, encoding: 'UTF-8')
    end

    # ── Parsování mastodon_accounts.yml ───────────────────────

    # Vrátí hash: { account_id => { categories: [...], instance: nil|"...", token: nil|"..." } }
    def load_accounts
      content = File.read(@accounts_file, encoding: 'UTF-8')
      accounts = {}
      current_id = nil

      content.each_line do |line|
        next if line.match?(/^\s*#/)

        if (m = line.match(/^([A-Za-z0-9_]+):\s*$/))
          current_id = m[1]
          accounts[current_id] = { categories: [], instance: nil, token: nil }
        elsif current_id
          if (m = line.match(/^\s+categories:\s*\[(.+)\]/))
            accounts[current_id][:categories] = m[1].split(',').map(&:strip)
          elsif (m = line.match(/^\s+instance:\s*(.+)/))
            raw = m[1].strip.gsub(/\A["']|["']\z/, '')
            # Extrahuj jen hostname
            raw = raw.sub(%r{\Ahttps?://}, '').chomp('/')
            accounts[current_id][:instance] = raw
          elsif (m = line.match(/^\s+token:\s*(.+)/))
            accounts[current_id][:token] = m[1].strip.gsub(/\A["']|["']\z/, '')
          end
        end
      end

      accounts
    end

    private

    # Sestaví mention pro účet (s doménou instance pokud se liší od default).
    def mention_for(account_id, accounts)
      info     = accounts[account_id] || {}
      instance = info[:instance] || @default_instance
      "@#{account_id}@#{instance}"
    end

    # Sestaví bloky pro nové účty ve FF stylu: "Název — @handle\nBio".
    def build_new_lines(new_ids, accounts)
      blocks = []
      new_ids.each_with_index do |id, idx|
        blocks << '' if idx > 0
        info     = accounts[id] || {}
        profile  = fetch_account_profile(id, info)
        instance = info[:instance] || @default_instance
        header   = "#{profile[:display_name]} \u2014 @#{id}@#{instance}"
        blocks << (profile[:bio] ? "#{header}\n#{profile[:bio]}" : header)
      end
      blocks
    end

    # Fetchne display_name a bio z Mastodon API.
    def fetch_account_profile(account_id, info)
      token    = info[:token]
      instance = instance_url_for(info)

      return { display_name: account_id, bio: nil } unless token

      uri  = URI("#{instance}/api/v1/accounts/verify_credentials")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = uri.scheme == 'https'
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{token}"

      response = http.request(req)
      unless (200..299).include?(response.code.to_i)
        warn "[source_report] #{account_id}: HTTP #{response.code}"
        return { display_name: account_id, bio: nil }
      end

      data         = JSON.parse(response.body)
      display_name = data['display_name'].to_s
      display_name = account_id if display_name.strip.empty?
      bio          = parse_bio(data['note'])

      { display_name: display_name, bio: bio }
    rescue StandardError => e
      warn "[source_report] #{account_id}: #{e.class} #{e.message}"
      { display_name: account_id, bio: nil }
    end

    def instance_url_for(info)
      inst = info[:instance].to_s.strip
      return "https://#{@default_instance}" if inst.empty?

      inst.start_with?('http') ? inst.chomp('/') : "https://#{inst.chomp('/')}"
    end

    def parse_bio(note)
      return nil if note.nil? || note.to_s.strip.empty?

      bio = HtmlCleaner.sanitize_html(note.to_s)
      bio = bio.gsub(/\s+/, ' ').strip
      return nil if bio.empty?

      return bio if bio.length <= BIO_MAX_CHARS

      truncated  = bio[0, BIO_MAX_CHARS - 1]
      last_space = truncated.rindex(' ')
      truncated  = truncated[0, last_space] if last_space
      "#{truncated.rstrip}\u2026"
    end

    # Sestaví thread: rozdělí intro + seznam řádků do postů ≤ MASTODON_CHAR_LIMIT.
    def build_thread(intro, lines, suffix)
      posts = []
      current_lines = []
      first = true

      lines.each do |line|
        candidate = build_post_text(first ? intro : nil, current_lines + [line], suffix)
        if candidate.length > MASTODON_CHAR_LIMIT && !current_lines.empty?
          posts << build_post_text(first ? intro : nil, current_lines, suffix)
          first = false
          current_lines = [line]
        else
          current_lines << line
        end
      end

      posts << build_post_text(first ? intro : nil, current_lines, suffix) unless current_lines.empty?
      posts
    end

    def build_post_text(intro, lines, suffix)
      parts = []
      parts << intro if intro
      parts << ''    if intro && !lines.empty?
      parts.concat(lines)
      parts.join("\n") + suffix
    end

    def publish_thread(posts)
      if @dry_run
        posts.each_with_index do |post, i|
          log "--- DRY-RUN post #{i + 1}/#{posts.size} (#{post.length} znaků) ---"
          log post
          log ''
        end
        return
      end

      unless @publisher
        warn '[source_report] Žádný publisher — post přeskočen.'
        return
      end

      reply_id = nil
      posts.each_with_index do |post, i|
        log "Publikuji post #{i + 1}/#{posts.size} (#{post.length} znaků)..."
        result = @publisher.publish(post, visibility: 'public', in_reply_to_id: reply_id)
        reply_id = result['id']
      rescue StandardError => e
        warn "[source_report] Chyba při publikování postu #{i + 1}: #{e.message}"
        raise  # Propaguj chybu — snapshot se neaktualizuje
      end
    end

    def log(msg)
      puts "[source_report] #{msg}"
    end
  end
end
