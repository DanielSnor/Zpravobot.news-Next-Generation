-- Patch: Přidat tabulku account_stats_snapshot pro ZpravobotStats
-- TASK: Zpravobot Týdeník (#ZpravobotStats)
-- Date: 2026-03-26
--
-- Idempotentní — bezpečné spustit vícekrát.
--
-- Run in prod schema:
--   SET search_path TO zpravobot; \i db/patch_add_stats_snapshot.sql
-- Run in test schema:
--   SET search_path TO zpravobot_test; \i db/patch_add_stats_snapshot.sql

-- ============================================================
-- Tabulka: account_stats_snapshot
-- ============================================================

CREATE TABLE IF NOT EXISTS account_stats_snapshot (
    account_id    VARCHAR(100) NOT NULL,
    snapshot_date DATE NOT NULL,
    followers     INTEGER,
    statuses      INTEGER,
    posts_week    INTEGER,
    PRIMARY KEY (account_id, snapshot_date)
);

CREATE INDEX IF NOT EXISTS idx_snapshot_date
    ON account_stats_snapshot (snapshot_date DESC);

COMMENT ON TABLE account_stats_snapshot IS 'Týdenní snapshoty Mastodon účtů pro ZpravobotStats';
COMMENT ON COLUMN account_stats_snapshot.account_id IS 'Identifikátor Mastodon účtu (z mastodon_accounts.yml)';
COMMENT ON COLUMN account_stats_snapshot.snapshot_date IS 'Datum snapshotu (typicky neděle)';
COMMENT ON COLUMN account_stats_snapshot.followers IS 'Počet sledujících z Mastodon API verify_credentials';
COMMENT ON COLUMN account_stats_snapshot.statuses IS 'Celkový počet statusů z Mastodon API verify_credentials';
COMMENT ON COLUMN account_stats_snapshot.posts_week IS 'Počet postů za daný týden z published_posts';
