-- writer.sql — pgbench: UPDATE losowego zywego (nieparzystego) wiersza bloat_t; maxhalf podaje repack_test.sh (-D)
-- writer.sql — pgbench: UPDATE of a random live (odd) row of bloat_t; maxhalf comes from repack_test.sh (-D)
\set id 2 * random(0, :maxhalf) + 1
UPDATE bloat_t SET v = v + 1 WHERE id = :id;
