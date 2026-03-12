-- Patch: Přidat tabulku media_fingerprints pro video SHA-256 deduplikaci
-- TASK: Video SHA-256 Deduplikace
-- Date: 2026-03-12
--
-- Vytvoří tabulku media_fingerprints + indexy + cleanup funkci.
-- Idempotentní — bezpečné spustit vícekrát.
--
-- Run in prod schema:
--   SET search_path TO zpravobot; \i db/patch_add_media_fingerprints.sql
-- Run in test schema:
--   SET search_path TO zpravobot_test; \i db/patch_add_media_fingerprints.sql

-- ============================================================
-- Tabulka: media_fingerprints
-- ============================================================

CREATE TABLE IF NOT EXISTS media_fingerprints (
    id          BIGSERIAL PRIMARY KEY,
    source_id   VARCHAR(100) NOT NULL,
    sha256_hash VARCHAR(64) NOT NULL,
    post_id     VARCHAR(255),
    media_url   TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE media_fingerprints IS 'SHA-256 fingerprints médií pro video deduplikaci (retence 96h)';
COMMENT ON COLUMN media_fingerprints.source_id IS 'Identifikátor zdroje/bota — deduplikace je per-source';
COMMENT ON COLUMN media_fingerprints.sha256_hash IS 'SHA-256 hex digest binárních dat videa';
COMMENT ON COLUMN media_fingerprints.post_id IS 'ID postu při prvním výskytu videa (pro diagnostiku)';
COMMENT ON COLUMN media_fingerprints.media_url IS 'URL média při prvním výskytu (pro diagnostiku)';

-- Unikátní index: jeden hash per source (UPSERT target)
CREATE UNIQUE INDEX IF NOT EXISTS idx_media_fp_source_hash
    ON media_fingerprints (source_id, sha256_hash);

-- Index pro cleanup (DELETE starých záznamů)
CREATE INDEX IF NOT EXISTS idx_media_fp_created
    ON media_fingerprints (created_at);

