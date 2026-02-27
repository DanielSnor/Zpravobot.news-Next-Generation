-- ============================================================
-- Zpravobot: Setup databáze a rolí
-- ============================================================
-- Spustit jako: postgres (superuser)
-- Jednorázově před první migrací
--
-- Použití:
--   # S ENV proměnnými (doporučeno):
--   OWNER_PASS='secure_password_1' APP_PASS='secure_password_2' \
--     psql -U postgres -f 01_setup_database.sql \
--     -v owner_pass="'$OWNER_PASS'" -v app_pass="'$APP_PASS'"
--
--   # Interaktivně (psql se zeptá):
--   psql -U postgres -f 01_setup_database.sql
--
-- ============================================================

-- Vytvoření databáze
CREATE DATABASE zpravobot
    ENCODING 'UTF8'
    LC_COLLATE 'cs_CZ.UTF-8'
    LC_CTYPE 'cs_CZ.UTF-8'
    TEMPLATE template0;

-- Komentář k databázi
COMMENT ON DATABASE zpravobot IS 'Zpravobot Next Generation - state management pro news aggregation';

-- ============================================================
-- Role
-- ============================================================

-- Prompt pro hesla pokud nejsou předány jako proměnné
\if :{?owner_pass}
\else
    \prompt 'Enter password for zpravobot_owner: ' owner_pass
\endif

\if :{?app_pass}
\else
    \prompt 'Enter password for zpravobot_app: ' app_pass
\endif

-- Owner role (DDL - migrace, vytváření tabulek)
CREATE ROLE zpravobot_owner WITH
    LOGIN
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE
    PASSWORD :owner_pass;

-- App role (DML - runtime operace)
CREATE ROLE zpravobot_app WITH
    LOGIN
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE
    PASSWORD :app_pass;

-- Přidělit databázi ownerovi
ALTER DATABASE zpravobot OWNER TO zpravobot_owner;

-- ============================================================
-- Výstup
-- ============================================================
\echo ''
\echo '✅ Databáze zpravobot vytvořena'
\echo '✅ Role zpravobot_owner vytvořena'
\echo '✅ Role zpravobot_app vytvořena'
\echo ''
\echo 'Další krok:'
\echo '  psql -U zpravobot_owner -d zpravobot -f 02_migrate_schema.sql'
\echo ''
