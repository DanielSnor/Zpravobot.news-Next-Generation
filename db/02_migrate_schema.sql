-- ============================================================
-- Zpravobot: Migrace schématu
-- ============================================================
-- Spustit jako: zpravobot_owner
-- Idempotentní - lze spouštět opakovaně
--
-- psql -U zpravobot_owner -d zpravobot -f 02_migrate_schema.sql
-- ============================================================

-- ============================================================
-- Schéma
-- ============================================================

CREATE SCHEMA IF NOT EXISTS zpravobot AUTHORIZATION zpravobot_owner;

-- Nastavit výchozí search_path pro tuto session
SET search_path TO zpravobot;

-- Odebrat public přístup
REVOKE ALL ON SCHEMA zpravobot FROM PUBLIC;

COMMENT ON SCHEMA zpravobot IS 'Zpravobot state management - published posts, source state, activity log';

-- ============================================================
-- Tabulka: published_posts
-- Hlavní tabulka pro tracking publikovaných postů
-- ============================================================

CREATE TABLE IF NOT EXISTS published_posts (
    id                  BIGSERIAL PRIMARY KEY,
    source_id           TEXT NOT NULL,                -- "ct24_twitter", "idnes_rss"
    post_id             TEXT NOT NULL,                -- ID z platformy
    post_url            TEXT,                         -- URL postu (pro debug)
    mastodon_status_id  TEXT,                         -- Mastodon ID
    platform_uri        TEXT,                         -- Platform-specific URI pro threading
    published_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT uq_source_post UNIQUE (source_id, post_id)
);

COMMENT ON TABLE published_posts IS 'Evidence publikovaných postů - deduplikace';
COMMENT ON COLUMN published_posts.source_id IS 'Identifikátor zdroje (bot), např. ct24_twitter';
COMMENT ON COLUMN published_posts.post_id IS 'Originální ID postu z platformy';
COMMENT ON COLUMN published_posts.mastodon_status_id IS 'ID statusu na Mastodonu po publikaci';
COMMENT ON COLUMN published_posts.platform_uri IS 'Platform-specific URI pro thread tracking (např. Bluesky AT URI)';

-- Indexy
CREATE INDEX IF NOT EXISTS idx_published_source_time
    ON published_posts (source_id, published_at DESC);

CREATE INDEX IF NOT EXISTS brin_published_at
    ON published_posts USING brin (published_at);

-- Unikátnost Mastodon statusu (pokud je vyplněn)
CREATE UNIQUE INDEX IF NOT EXISTS uq_published_mastodon_status
    ON published_posts (mastodon_status_id)
    WHERE mastodon_status_id IS NOT NULL;

-- Index pro thread lookup by platform_uri
CREATE INDEX IF NOT EXISTS idx_published_platform_uri
    ON published_posts (platform_uri)
    WHERE platform_uri IS NOT NULL;

-- Composite index pro source + platform_uri (find_by_platform_uri)
CREATE INDEX IF NOT EXISTS idx_published_source_platform_uri
    ON published_posts (source_id, platform_uri)
    WHERE platform_uri IS NOT NULL;

-- ============================================================
-- Migrace: přidat platform_uri pokud neexistuje
-- ============================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'zpravobot'
        AND table_name = 'published_posts'
        AND column_name = 'platform_uri'
    ) THEN
        ALTER TABLE published_posts 
        ADD COLUMN platform_uri TEXT;
        
        COMMENT ON COLUMN published_posts.platform_uri IS 
            'Platform-specific URI pro thread tracking (např. Bluesky AT URI)';
        
        RAISE NOTICE 'Sloupec platform_uri přidán do published_posts';
    END IF;
END $$;

-- ============================================================
-- Tabulka: source_state
-- Stav jednotlivých zdrojů (scheduling, error tracking)
-- ============================================================

CREATE TABLE IF NOT EXISTS source_state (
    source_id       TEXT PRIMARY KEY,
    last_check      TIMESTAMPTZ,                      -- Kdy naposledy zkontrolován
    last_success    TIMESTAMPTZ,                      -- Kdy naposledy úspěšně
    posts_today     INTEGER NOT NULL DEFAULT 0,       -- Počet postů dnes
    last_reset      DATE NOT NULL DEFAULT CURRENT_DATE, -- Kdy naposledy resetován posts_today
    error_count     INTEGER NOT NULL DEFAULT 0,       -- Počet po sobě jdoucích chyb
    last_error      TEXT,                             -- Poslední chybová zpráva
    disabled_at     TIMESTAMPTZ,                      -- NULL = aktivní; NOT NULL = pozastaven (manage_source.rb pause)
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE source_state IS 'Stav zdrojů - scheduling a error tracking';
COMMENT ON COLUMN source_state.posts_today IS 'Počet publikovaných postů dnes (reset o půlnoci)';
COMMENT ON COLUMN source_state.last_reset IS 'Datum posledního resetu posts_today';
COMMENT ON COLUMN source_state.error_count IS 'Počet po sobě jdoucích chyb (reset při úspěchu)';
COMMENT ON COLUMN source_state.disabled_at IS 'NULL = zdroj aktivní; NOT NULL = zdroj pozastaven (manage_source.rb pause)';

-- Migrace: přidat last_reset pokud neexistuje (pro existující DB)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'zpravobot'
        AND table_name = 'source_state'
        AND column_name = 'last_reset'
    ) THEN
        ALTER TABLE source_state
        ADD COLUMN last_reset DATE NOT NULL DEFAULT CURRENT_DATE;

        RAISE NOTICE 'Sloupec last_reset přidán do source_state';
    END IF;
END $$;

-- Migrace: přidat disabled_at pokud neexistuje (pro existující DB)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'zpravobot'
        AND table_name = 'source_state'
        AND column_name = 'disabled_at'
    ) THEN
        ALTER TABLE source_state
        ADD COLUMN disabled_at TIMESTAMPTZ DEFAULT NULL;

        RAISE NOTICE 'Sloupec disabled_at přidán do source_state';
    END IF;
END $$;

-- Trigger pro automatickou aktualizaci updated_at
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS trg_source_state_updated_at ON source_state;

CREATE TRIGGER trg_source_state_updated_at
    BEFORE UPDATE ON source_state
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Partial index pro rychlé reporty chyb
CREATE INDEX IF NOT EXISTS idx_sources_with_errors
    ON source_state (error_count)
    WHERE error_count > 0;

-- ============================================================
-- Tabulka: activity_log
-- Diagnostický log pro debugging
-- ============================================================

CREATE TABLE IF NOT EXISTS activity_log (
    id          BIGSERIAL PRIMARY KEY,
    source_id   TEXT,                                 -- Může být NULL (systémové logy)
    action      VARCHAR(50) NOT NULL,
    details     JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT chk_action_valid CHECK (action IN (
        'fetch',
        'publish',
        'skip',
        'error',
        'profile_sync',
        'media_upload',
        'transient_error'
    ))
);

COMMENT ON TABLE activity_log IS 'Diagnostický log - append-only';
COMMENT ON COLUMN activity_log.action IS 'Typ akce: fetch, publish, skip, error, profile_sync, media_upload, transient_error';
COMMENT ON COLUMN activity_log.details IS 'JSON s detaily akce (post_url, error_message, ...)';

-- Indexy
CREATE INDEX IF NOT EXISTS idx_activity_source_time
    ON activity_log (source_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_activity_created
    ON activity_log (created_at DESC);

-- ============================================================
-- Tabulka: edit_detection_buffer
-- Buffer pro detekci editovaných tweetů (retence 2 hodiny)
-- ============================================================

CREATE TABLE IF NOT EXISTS edit_detection_buffer (
    id              BIGSERIAL PRIMARY KEY,
    source_id       VARCHAR(100) NOT NULL,      -- Bot/source identifier
    post_id         VARCHAR(255) NOT NULL,      -- Original platform post ID
    username        VARCHAR(100) NOT NULL,      -- Twitter handle (lowercase)
    text_normalized TEXT NOT NULL,              -- Normalized text for similarity comparison
    text_hash       VARCHAR(64),                -- SHA-256 hash for quick exact-match check
    mastodon_id     TEXT,                       -- Mastodon status ID (if already published)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_edit_buffer_source_post UNIQUE (source_id, post_id)
);

COMMENT ON TABLE edit_detection_buffer IS 'Buffer pro detekci editovaných tweetů (retence 2 hodiny)';
COMMENT ON COLUMN edit_detection_buffer.source_id IS 'Identifikátor zdroje/bota';
COMMENT ON COLUMN edit_detection_buffer.post_id IS 'Originální ID tweetu';
COMMENT ON COLUMN edit_detection_buffer.username IS 'Twitter handle (lowercase, bez @)';
COMMENT ON COLUMN edit_detection_buffer.text_normalized IS 'Normalizovaný text pro similarity matching';
COMMENT ON COLUMN edit_detection_buffer.text_hash IS 'SHA-256 hash normalizovaného textu';
COMMENT ON COLUMN edit_detection_buffer.mastodon_id IS 'Mastodon status ID pokud už publikováno';

CREATE INDEX IF NOT EXISTS idx_edit_buffer_username_time
    ON edit_detection_buffer (username, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_edit_buffer_hash
    ON edit_detection_buffer (username, text_hash)
    WHERE text_hash IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_edit_buffer_created
    ON edit_detection_buffer (created_at);

CREATE OR REPLACE FUNCTION cleanup_edit_detection_buffer(retention_hours INTEGER DEFAULT 2)
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM edit_detection_buffer
    WHERE created_at < NOW() - (retention_hours || ' hours')::INTERVAL;

    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION cleanup_edit_detection_buffer IS 'Smaže záznamy starší než retention_hours (default 2)';

-- ============================================================
-- Práva pro zpravobot_app
-- ============================================================

GRANT USAGE ON SCHEMA zpravobot TO zpravobot_app;

GRANT SELECT, INSERT, UPDATE, DELETE 
    ON ALL TABLES IN SCHEMA zpravobot 
    TO zpravobot_app;

GRANT USAGE, SELECT 
    ON ALL SEQUENCES IN SCHEMA zpravobot 
    TO zpravobot_app;

-- Default privileges pro budoucí tabulky
ALTER DEFAULT PRIVILEGES IN SCHEMA zpravobot
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO zpravobot_app;

ALTER DEFAULT PRIVILEGES IN SCHEMA zpravobot
    GRANT USAGE, SELECT ON SEQUENCES TO zpravobot_app;

-- ============================================================
-- Výstup
-- ============================================================

\echo ''
\echo '✅ Schéma zpravobot vytvořeno'
\echo '✅ Tabulka published_posts vytvořena (včetně platform_uri)'
\echo '✅ Tabulka source_state vytvořena (včetně last_reset)'
\echo '✅ Tabulka activity_log vytvořena'
\echo '✅ Tabulka edit_detection_buffer vytvořena (včetně cleanup funkce)'
\echo '✅ Práva pro zpravobot_app nastavena'
\echo ''
\echo 'Ověření:'
\echo '  psql -U zpravobot_app -d zpravobot -c "SELECT column_name FROM information_schema.columns WHERE table_schema = ''zpravobot'' AND table_name = ''published_posts'';"'
\echo ''
