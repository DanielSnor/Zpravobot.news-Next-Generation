-- Patch: Reset stale error_count for sources that are running fine
-- TASK-5: Health Monitor false positives from old YouTube outage data
-- Date: 2026-02-19
--
-- Resets error_count for sources where last_success is more recent
-- than last_check (i.e., the source has succeeded since any errors).
-- Safe to run multiple times (idempotent).
--
-- Run in prod schema:
--   SET search_path TO zpravobot; \i db/patch_reset_stale_error_counts.sql
-- Run in test schema:
--   SET search_path TO zpravobot_test; \i db/patch_reset_stale_error_counts.sql

UPDATE source_state
SET error_count = 0,
    last_error  = NULL
WHERE error_count > 0
  AND last_success > COALESCE(last_check, '1970-01-01'::timestamptz);
