SET jit = off;
EXPLAIN (ANALYZE, FORMAT JSON)
INSERT INTO zamowienie (id, klient_id, kwota)
SELECT g, 1 + (g * 2654435761) % 100000, (g % 100000) / 100.0
FROM generate_series(1, 5000000) g;
