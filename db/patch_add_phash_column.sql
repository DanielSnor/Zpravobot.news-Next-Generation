-- Patch: Přidat phash_int sloupec do media_fingerprints
-- TASK: Video pHash Deduplikace (nahrazení SHA-256 perceptuálním hashem)
-- Date: 2026-03-14
--
-- Přidává phash_int BIGINT sloupec pro aHash (Average Hash) via ImageMagick.
-- NULL pro URL-hash záznamy (velká videa >10MB kde pHash nelze spočítat).
-- Idempotentní — bezpečné spustit vícekrát.
--
-- Run in prod schema:
--   SET search_path TO zpravobot; \i db/patch_add_phash_column.sql
-- Run in test schema:
--   SET search_path TO zpravobot_test; \i db/patch_add_phash_column.sql

ALTER TABLE media_fingerprints
  ADD COLUMN IF NOT EXISTS phash_int BIGINT;

COMMENT ON COLUMN media_fingerprints.phash_int IS
  'aHash (average hash) 64-bit integer via ImageMagick convert; NULL pro URL-hash záznamy (videa >10MB)';
