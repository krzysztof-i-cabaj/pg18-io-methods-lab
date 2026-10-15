-- ==============================================================================
-- Tytul:        01_create_test_data.sql
-- Opis:         Tabela testowa fakty: 100 mln wierszy (~13-14 GB, 3-4x RAM VM),
--               generowana deterministycznie (setseed). Kolumny d i r losowe,
--               NIESKORELOWANE z fizycznym porzadkiem (Bitmap/Index Scan = losowe I/O).
--               Indeksy na d i r, VACUUM ANALYZE, CHECKPOINT.
-- Description [EN]: Test table fakty: 100M rows (~13-14 GB, 3-4x VM RAM), generated
--               deterministically (setseed). Columns d and r random, NOT correlated
--               with physical order. Indexes on d and r, VACUUM ANALYZE, CHECKPOINT.
--
-- Autor:        KCB Kris
-- Data:         2026-10-15
-- Wersja:       1.0
-- Konwencje:    <repo>/SETTINGS.md
--
-- Wymagania [PL]:    - PostgreSQL 18, baza postgres, superuser, ~25 GB wolnego na /pgdata
-- Requirements [EN]: - PostgreSQL 18, postgres DB, superuser, ~25 GB free on /pgdata
--
-- Uzycie [PL]:       .\lab.ps1 loaddata   (psql -v ON_ERROR_STOP=1 -f na VM, w tle)
-- Usage [EN]:        .\lab.ps1 loaddata
-- ==============================================================================
\set ON_ERROR_STOP on
\timing on

-- KROK 1: podglad / preview -----------------------------------------------------
SELECT current_setting('server_version') AS wersja,
       pg_size_pretty(pg_database_size(current_database())) AS rozmiar_bazy,
       to_regclass('public.fakty') AS istniejaca_tabela;

-- KROK 2: tabela (bez nadpisywania istniejacej) / table (no overwrite) ---------
CREATE TABLE fakty (
    id   bigint           NOT NULL,
    d    date             NOT NULL,   -- 2020-01-01 .. 2024-12-31, losowo / random
    k    integer          NOT NULL,   -- 0..999
    r    bigint           NOT NULL,   -- 0..1e12, losowo / random
    v    double precision NOT NULL,
    pad  text             NOT NULL    -- 64 znaki (2x md5), poszerza wiersz / widens the row
);

SELECT setseed(0.42);

-- 10 paczek po 10 mln (postep w logu); ta sama sesja => deterministyczne random()
-- 10 batches of 10M (progress in log); same session => deterministic random()
\echo 'paczka 1/10'
INSERT INTO fakty SELECT g, date '2020-01-01' + (random()*1826)::int, (random()*999)::int,
       (random()*1e12)::bigint, random()*1000, md5(g::text) || md5((g+7)::text)
FROM generate_series(1, 10000000) g;
\echo 'paczka 2/10'
INSERT INTO fakty SELECT g, date '2020-01-01' + (random()*1826)::int, (random()*999)::int,
       (random()*1e12)::bigint, random()*1000, md5(g::text) || md5((g+7)::text)
FROM generate_series(10000001, 20000000) g;
\echo 'paczka 3/10'
INSERT INTO fakty SELECT g, date '2020-01-01' + (random()*1826)::int, (random()*999)::int,
       (random()*1e12)::bigint, random()*1000, md5(g::text) || md5((g+7)::text)
FROM generate_series(20000001, 30000000) g;
\echo 'paczka 4/10'
INSERT INTO fakty SELECT g, date '2020-01-01' + (random()*1826)::int, (random()*999)::int,
       (random()*1e12)::bigint, random()*1000, md5(g::text) || md5((g+7)::text)
FROM generate_series(30000001, 40000000) g;
\echo 'paczka 5/10'
INSERT INTO fakty SELECT g, date '2020-01-01' + (random()*1826)::int, (random()*999)::int,
       (random()*1e12)::bigint, random()*1000, md5(g::text) || md5((g+7)::text)
FROM generate_series(40000001, 50000000) g;
\echo 'paczka 6/10'
INSERT INTO fakty SELECT g, date '2020-01-01' + (random()*1826)::int, (random()*999)::int,
       (random()*1e12)::bigint, random()*1000, md5(g::text) || md5((g+7)::text)
FROM generate_series(50000001, 60000000) g;
\echo 'paczka 7/10'
INSERT INTO fakty SELECT g, date '2020-01-01' + (random()*1826)::int, (random()*999)::int,
       (random()*1e12)::bigint, random()*1000, md5(g::text) || md5((g+7)::text)
FROM generate_series(60000001, 70000000) g;
\echo 'paczka 8/10'
INSERT INTO fakty SELECT g, date '2020-01-01' + (random()*1826)::int, (random()*999)::int,
       (random()*1e12)::bigint, random()*1000, md5(g::text) || md5((g+7)::text)
FROM generate_series(70000001, 80000000) g;
\echo 'paczka 9/10'
INSERT INTO fakty SELECT g, date '2020-01-01' + (random()*1826)::int, (random()*999)::int,
       (random()*1e12)::bigint, random()*1000, md5(g::text) || md5((g+7)::text)
FROM generate_series(80000001, 90000000) g;
\echo 'paczka 10/10'
INSERT INTO fakty SELECT g, date '2020-01-01' + (random()*1826)::int, (random()*999)::int,
       (random()*1e12)::bigint, random()*1000, md5(g::text) || md5((g+7)::text)
FROM generate_series(90000001, 100000000) g;

-- KROK 3: indeksy, statystyki / indexes, statistics -----------------------------
\echo 'indeksy'
ALTER TABLE fakty ADD PRIMARY KEY (id);
CREATE INDEX fakty_d_idx ON fakty (d);
CREATE INDEX fakty_r_idx ON fakty (r);
\echo 'vacuum analyze'
VACUUM (ANALYZE) fakty;
CHECKPOINT;

-- KROK 4: weryfikacja / verification --------------------------------------------
SELECT count(*)                                         AS liczba_wierszy,
       min(d) AS min_d, max(d) AS max_d,
       pg_size_pretty(pg_relation_size('fakty'))        AS rozmiar_tabeli,
       pg_size_pretty(pg_indexes_size('fakty'))         AS rozmiar_indeksow,
       (SELECT correlation FROM pg_stats WHERE tablename = 'fakty' AND attname = 'd') AS korelacja_d,
       (SELECT correlation FROM pg_stats WHERE tablename = 'fakty' AND attname = 'r') AS korelacja_r
FROM fakty;
\echo 'LOAD OK'
