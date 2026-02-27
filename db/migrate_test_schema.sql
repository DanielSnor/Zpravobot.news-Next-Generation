-- ============================================================
-- Zpravobot: Testovací schéma (Cloudron)
-- ============================================================
-- Spustit po migrate_cloudron.sql
--
-- psql "$CLOUDRON_POSTGRESQL_URL" -f db/migrate_test_schema.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS zpravobot_test;

COMMENT ON SCHEMA zpravobot_test IS 'Zpravobot TEST - pro vývoj a testování';

SET search_path TO zpravobot_test;

-- ============================================================
-- Tabulka: published_posts
-- ============================================================

CREATE TABLE IF NOT EXISTS published_posts (
    id                  BIGSERIAL PRIMARY KEY,
    source_id           VARCHAR(100) NOT NULL,
    post_id             VARCHAR(255) NOT NULL,
    post_url            TEXT,
    mastodon_status_id  TEXT,
    platform_uri        TEXT,                         -- Platform-specific URI for threading
    published_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_source_post UNIQUE (source_id, post_id)
);

COMMENT ON TABLE published_posts IS 'Evidence publikovaných postů - deduplikace';
COMMENT ON COLUMN published_posts.platform_uri IS 'Platform-specific URI pro thread tracking (např. Bluesky AT URI)';

CREATE INDEX IF NOT EXISTS idx_published_source_time
    ON published_posts (source_id, published_at DESC);

CREATE INDEX IF NOT EXISTS brin_published_at
    ON published_posts USING brin (published_at);

CREATE UNIQUE INDEX IF NOT EXISTS uq_published_mastodon_status
    ON published_posts (mastodon_status_id)
    WHERE mastodon_status_id IS NOT NULL;

-- Index pro thread lookup by platform_uri
CREATE INDEX IF NOT EXISTS idx_published_platform_uri
    ON published_posts (platform_uri)
    WHERE platform_uri IS NOT NULL;

-- Composite index pro source + platform_uri
CREATE INDEX IF NOT EXISTS idx_published_source_platform_uri
    ON published_posts (source_id, platform_uri)
    WHERE platform_uri IS NOT NULL;

-- Migrace: přidat platform_uri pokud neexistuje
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'zpravobot_test'
        AND table_name = 'published_posts'
        AND column_name = 'platform_uri'
    ) THEN
        ALTER TABLE published_posts 
        ADD COLUMN platform_uri TEXT;
        
        RAISE NOTICE 'Sloupec platform_uri přidán do published_posts';
    END IF;
END $$;

-- ============================================================
-- Tabulka: source_state
-- ============================================================

CREATE TABLE IF NOT EXISTS source_state (
    source_id       VARCHAR(100) PRIMARY KEY,
    last_check      TIMESTAMPTZ,
    last_success    TIMESTAMPTZ,
    posts_today     INTEGER NOT NULL DEFAULT 0,
    last_reset      DATE NOT NULL DEFAULT CURRENT_DATE,
    error_count     INTEGER NOT NULL DEFAULT 0,
    last_error      TEXT,
    disabled_at     TIMESTAMPTZ,                      -- NULL = aktivní; NOT NULL = pozastaven (manage_source.rb pause)
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE source_state IS 'Stav zdrojů - scheduling a error tracking';
COMMENT ON COLUMN source_state.posts_today IS 'Počet publikovaných postů dnes (reset o půlnoci)';
COMMENT ON COLUMN source_state.last_reset IS 'Datum posledního resetu posts_today';
COMMENT ON COLUMN source_state.disabled_at IS 'NULL = zdroj aktivní; NOT NULL = zdroj pozastaven (manage_source.rb pause)';

-- Migrace: přidat last_reset pokud neexistuje
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'zpravobot_test'
        AND table_name = 'source_state'
        AND column_name = 'last_reset'
    ) THEN
        ALTER TABLE source_state
        ADD COLUMN last_reset DATE NOT NULL DEFAULT CURRENT_DATE;

        RAISE NOTICE 'Sloupec last_reset přidán do source_state';
    END IF;
END $$;

-- Migrace: přidat disabled_at pokud neexistuje
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'zpravobot_test'
        AND table_name = 'source_state'
        AND column_name = 'disabled_at'
    ) THEN
        ALTER TABLE source_state
        ADD COLUMN disabled_at TIMESTAMPTZ DEFAULT NULL;

        RAISE NOTICE 'Sloupec disabled_at přidán do source_state';
    END IF;
END $$;

-- Trigger pro updated_at
CREATE OR REPLACE FUNCTION zpravobot_test.set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS trg_source_state_updated_at ON source_state;

CREATE TRIGGER trg_source_state_updated_at
    BEFORE UPDATE ON source_state
    FOR EACH ROW EXECUTE FUNCTION zpravobot_test.set_updated_at();

-- Partial index pro rychlé reporty chyb
CREATE INDEX IF NOT EXISTS idx_sources_with_errors
    ON source_state (error_count)
    WHERE error_count > 0;

-- ============================================================
-- Tabulka: activity_log
-- ============================================================

CREATE TABLE IF NOT EXISTS activity_log (
    id          BIGSERIAL PRIMARY KEY,
    source_id   VARCHAR(100),
    action      VARCHAR(50) NOT NULL,
    details     JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT chk_action_valid CHECK (action IN (
        'fetch','publish','skip','error','profile_sync','media_upload','transient_error'
    ))
);

COMMENT ON TABLE activity_log IS 'Diagnostický log - append-only';

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
    source_id       VARCHAR(100) NOT NULL,
    post_id         VARCHAR(255) NOT NULL,
    username        VARCHAR(100) NOT NULL,
    text_normalized TEXT NOT NULL,
    text_hash       VARCHAR(64),
    mastodon_id     TEXT,
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

CREATE OR REPLACE FUNCTION zpravobot_test.cleanup_edit_detection_buffer(retention_hours INTEGER DEFAULT 2)
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM zpravobot_test.edit_detection_buffer
    WHERE created_at < NOW() - (retention_hours || ' hours')::INTERVAL;

    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION zpravobot_test.cleanup_edit_detection_buffer IS 'Smaže záznamy starší než retention_hours (default 2)';

-- ============================================================
-- Výstup
-- ============================================================

\echo ''
\echo '✅ Testovací schéma zpravobot_test vytvořeno/aktualizováno'
\echo '✅ Tabulka published_posts (včetně platform_uri)'
\echo '✅ Tabulka source_state (včetně last_reset)'
\echo '✅ Tabulka activity_log'
\echo '✅ Tabulka edit_detection_buffer (včetně cleanup funkce)'
\echo ''
