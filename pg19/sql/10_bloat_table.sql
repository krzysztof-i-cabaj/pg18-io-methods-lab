-- ==============================================================================
-- Tytul:        10_bloat_table.sql
-- Opis:         Tabela testowa bloat_t do testu R (REPACK vs VACUUM FULL): :rows wierszy
--               (deterministycznie, setseed), PK + indeks na k, DELETE co drugiego
--               wiersza i zwykly VACUUM — plik nie maleje, 50% wolnego miejsca w srodku.
--               Tworzona od nowa w kazdej serii (tabela tylko do testu, w bazie labtest).
-- Description [EN]: Test table bloat_t for test R (REPACK vs VACUUM FULL): :rows rows
--               (deterministic, setseed), PK + index on k, every other row deleted and a
--               plain VACUUM — the file does not shrink, 50% free space inside.
--               Recreated in every series (test-only table in database labtest).
--
-- Autor:        KCB Kris
-- Data:         2026-11-23
-- Wersja:       1.0
-- Konwencje:    <repo>/SETTINGS.md
--
-- Wymagania [PL]:    - PostgreSQL 18 lub 19, baza labtest, superuser; ~2x rozmiar tabeli wolnego
-- Requirements [EN]: - PostgreSQL 18 or 19, database labtest, superuser; ~2x table size free
--
-- Uzycie [PL]:       psql -p <port> -d labtest -v rows=20000000 -f 10_bloat_table.sql
--                    (wywoluje bench/repack_test.sh)
-- Usage [EN]:        same (called by bench/repack_test.sh)
-- ==============================================================================
\set ON_ERROR_STOP on

-- KROK 1: podglad / preview -----------------------------------------------------
SELECT current_setting('server_version') AS wersja,
       :rows                             AS wierszy_do_utworzenia,
       to_regclass('public.bloat_t')     AS poprzednia_tabela;

-- KROK 2: tabela od nowa (tylko tabela testowa labu) / table from scratch (lab test table only)
DROP TABLE IF EXISTS bloat_t;
CREATE TABLE bloat_t (
    id   bigint           NOT NULL PRIMARY KEY,
    k    integer          NOT NULL,   -- 0..999
    v    double precision NOT NULL,
    pad  text             NOT NULL    -- 64 znaki, poszerza wiersz / widens the row
);

SELECT setseed(0.42);
INSERT INTO bloat_t
SELECT g, (random() * 999)::int, random() * 1000, md5(g::text) || md5((g + 7)::text)
FROM generate_series(1, :rows) g;
CREATE INDEX bloat_t_k_idx ON bloat_t (k);

-- Rozdecie: polowa wierszy usunieta, zwykly VACUUM zwalnia miejsce w pliku, ale go nie skraca.
-- Bloat: half of the rows deleted; plain VACUUM frees space inside the file but does not shrink it.
DELETE FROM bloat_t WHERE id % 2 = 0;
VACUUM (ANALYZE) bloat_t;
CHECKPOINT;

-- KROK 3: weryfikacja / verification ---------------------------------------------
SELECT count(*)                                         AS liczba_wierszy,
       pg_size_pretty(pg_relation_size('bloat_t'))      AS rozmiar_tabeli,
       pg_size_pretty(pg_indexes_size('bloat_t'))       AS rozmiar_indeksow
FROM bloat_t;
