-- ==============================================================================
-- Tytul:        20_fk_tables.sql
-- Opis:         Tabela nadrzedna klient (:parents wierszy, PK) do testu F (klucze obce
--               przy masowym INSERT). Tabele zamowienie tworzy bench/fk_test.sh w kazdej
--               serii. Tworzona od nowa (tabela tylko do testu, w bazie labtest).
-- Description [EN]: Parent table klient (:parents rows, PK) for test F (foreign keys on
--               bulk INSERT). bench/fk_test.sh creates the zamowienie table per series.
--               Recreated from scratch (test-only table in database labtest).
--
-- Autor:        KCB Kris
-- Data:         2026-11-23
-- Wersja:       1.0
-- Konwencje:    <repo>/SETTINGS.md
--
-- Wymagania [PL]:    - PostgreSQL 18 lub 19, baza labtest, superuser
-- Requirements [EN]: - PostgreSQL 18 or 19, database labtest, superuser
--
-- Uzycie [PL]:       psql -p <port> -d labtest -v parents=100000 -f 20_fk_tables.sql
--                    (wywoluje bench/fk_test.sh)
-- Usage [EN]:        same (called by bench/fk_test.sh)
-- ==============================================================================
\set ON_ERROR_STOP on

-- KROK 1: podglad / preview -----------------------------------------------------
SELECT current_setting('server_version') AS wersja,
       :parents                          AS klientow_do_utworzenia,
       to_regclass('public.klient')      AS poprzednia_tabela;

-- KROK 2: tabele od nowa / tables from scratch -----------------------------------
DROP TABLE IF EXISTS zamowienie;
DROP TABLE IF EXISTS klient;
CREATE TABLE klient (
    id     bigint NOT NULL PRIMARY KEY,
    nazwa  text   NOT NULL
);
INSERT INTO klient SELECT g, 'klient ' || g FROM generate_series(1, :parents) g;
VACUUM (ANALYZE) klient;
CHECKPOINT;

-- KROK 3: weryfikacja / verification ---------------------------------------------
SELECT count(*) AS liczba_klientow,
       pg_size_pretty(pg_total_relation_size('klient')) AS rozmiar_z_indeksem
FROM klient;
