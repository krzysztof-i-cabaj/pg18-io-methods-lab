# 🔬 RESULTS — PostgreSQL 19 vs 18: REPACK, foreign keys, pg_upgrade --check

[![Measured](https://img.shields.io/badge/Measured-2026--11--23-blue)]()
[![Runs](https://img.shields.io/badge/Runs-R_27_%C2%B7_F_20_ok-success)]()
[![VM](https://img.shields.io/badge/VM-pgio_4vCPU_3.6GB_NVMe-orange)]()
[![PG](https://img.shields.io/badge/PostgreSQL-18.6_vs_19.0-336791)]()

> 🎯 What the three tests showed, how to read it and what these numbers do not say. Raw data: `../results/`
> (`*_20261123_183133_full*` part 1, `*_192156_full*` part 2, `*_194837_full*` control), median tables:
> `../results/SUMMARY_*.md` (Polish column names). 🇵🇱 [Wersja polska](RESULTS_PL.md) · interactive page:
> <https://krzysztof-i-cabaj.github.io/pg18-io-methods-lab/pg19/>

## 📌 Key findings

1. **Foreign keys: "nearly 2×" confirmed** — bulk INSERT of 5 M rows with an FK: PG18 27.6 s → PG19 14.4 s (**1.92×**);
   the FK check alone got 2.36× cheaper. Run-to-run spread < 7%.
2. **`REPACK (CONCURRENTLY)` is not "zero downtime"** — writes go on during the copy, but stall at the end, and that end grows
   with traffic: **0 / 5 / 18 s** at 1 / 4 / 8 sessions. With 8 sessions `VACUUM FULL` blocked for less (15 s).
3. **`pg_upgrade --check` 18 → 19: `Clusters are compatible`** (copy and link) — a simple cluster without extensions hits
   none of the new blockers.

## 🧹 Test R — REPACK (CONCURRENTLY) vs VACUUM FULL

Table `bloat_t`: 20 M rows; after deleting half and a plain `VACUUM` it is 2404 MB (2.3 GB, half empty). During the operation
`pgbench` keeps running an `UPDATE` of a random row by primary key. 3 runs per variant.

### Part 1: 4 sessions, PG18 and PG19

| Variant | Operation time | Writes during (tps) | Seconds at 0 tps | Longest write wait | Table after |
|---|---|---|---|---|---|
| PG18 `VACUUM FULL` | **14.6 s** (14.2–14.8) | 731 | **14** (13–14) | **14.6 s** | 1211 MB |
| PG19 `VACUUM FULL` | **13.7 s** (13.6–13.7) | 752 | **13** | **13.7 s** | 1210 MB |
| PG19 `REPACK (CONCURRENTLY)` | **32.7 s** (32.6–34.3) | **3198** | **5** (5–6) | **6.2 s** (5.8–6.8) | 1218 MB |

Run 1, per second (`timeline_19_repack_concurrently_1.csv`): 0–9 s about 2000 tps (copy), 10–26 s 4000–6300 tps,
**27–31 s zero**, at 32 s the queued transactions (they waited 5818 ms), from 33 s 6600–9000 tps.

### Part 2 and control: 1 / 4 / 8 sessions (PG19)

| Sessions (writes/s before) | VACUUM FULL: writes stalled | REPACK (CONC.): writes stalled | REPACK time | Longest wait VF / REPACK |
|---|---|---|---|---|
| 1 (~1,700–1,900) | 11 s | **0 s** | 13.6 s | 12.3 s / **0.1 s** |
| 4 (~5,700) | 13 s | **5 s** | 32.5 s | 13.7 s / 6.1 s |
| 8 (~7,600–9,400) | **15 s** (15–21) | **18 s** (18–19) | 93.1 s | 16.1 s / 19.6 s |

### What it means

- **The version does not change the old command.** `VACUUM FULL` in 19 is ~6% faster (13.7 vs 14.6 s) but blocks the same way:
  `ACCESS EXCLUSIVE` from the first to the last second. The difference in R comes from the **new command**, not the new version.
- **REPACK (CONCURRENTLY) blocks at the end, not at the start.** Per the documentation most of the work runs under
  `SHARE UPDATE EXCLUSIVE` and `ACCESS EXCLUSIVE` is taken only for the swap. PG19 logged it itself (`log_lock_waits` is on by
  default): `acquired RowExclusiveLock … after 5818 ms` (6231 and 6795 ms in runs 2–3).
- **The end grows with traffic: 0 → 5 → 18 s.** Under the lock REPACK applies the changes captured by logical decoding; the more
  writes meanwhile, the longer it takes. The PostgreSQL 19 documentation says the same: *"the lock is typically held for a short
  time, depending on the amount of changes accumulated while the lock was being waited for"* — the measurement says what
  "short" means in seconds.
- **The REPACK advantage shrinks and disappears at 8 sessions:** median 18 s vs 15 s. Caveat: at 8 sessions the 4 vCPUs are
  saturated (part of the slowdown is CPU contention), and the load before the operation differed between runs (VF 7,500–8,700 tps,
  REPACK ~9,400 tps). Safe wording: "comparable or worse".
- **Lost work at 4 sessions is similar, just distributed differently.** Estimate from medians (tps before × time − tps during ×
  time): VF ≈ **72 k** fewer transactions, REPACK ≈ **78 k**. The gain of REPACK is a **shorter longest wait** (6 s instead of
  14 s — the difference between hitting an application timeout or not) and a table that accepts writes for 80% of the time.
- **Size:** both variants reclaimed half (2404 → ~1211 MB); REPACK leaves ~7 MB more (row versions from the copy period).
- **MVCC:** REPACK (CONCURRENTLY) is not MVCC-safe, `VACUUM FULL` is (documentation section 13.6 lists only `TRUNCATE`,
  table-rewriting `ALTER TABLE` and REPACK CONCURRENTLY).

### What to do about it

- Run it off-peak: under light traffic REPACK (CONCURRENTLY) really does not stop writes.
- Give the application room to wait a few seconds (`lock_timeout`, `statement_timeout`) — the final phase blocks reads of the table too.
- Measure the end on your own system: in PG19 `log_lock_waits` is on by default and the log shows `acquired … after N ms`.

## 🔗 Test F — foreign key on bulk INSERT

`INSERT … SELECT` of 5 M rows into `zamowienie` (orders, no indexes) with an FK to `klient` (customers, 100 k rows, PK) and
without the FK. `jit = off` in both versions. 5 runs, order of versions and variants alternating.

| PG | With FK | Without FK | FK cost (difference) | RI trigger time (EXPLAIN) | Trigger calls |
|---|---|---|---|---|---|
| 18 | **27.6 s** (27.2–29.2) | 5.0 s | **22.6 s** | 22.3 s | 5,000,000 |
| 19 | **14.4 s** (14.2–14.5) | 4.9 s | **9.6 s** | 9.4 s | 5,000,000 |
| 18 / 19 | **1.92×** | 1.04× | **2.36×** | 2.37× | — |

- **The announcement holds for this scenario:** the whole INSERT 1.92× faster; the "does the customer exist" part 2.36×
  (from ~4.5 µs to ~1.9 µs per row).
- **It is still a per-row trigger** — 5 M calls in both versions; in 19 each call is cheaper.
- **Without the FK the versions are almost equal** (5.0 vs 4.9 s) — the speed-up is about foreign keys, not inserts in general.
- **In a real table the gain will be smaller:** here the child table has no indexes and the parent fits in memory. Indexes, WAL
  with replication and application triggers add costs that 19 does not speed up.

## ⬆️ Test U — pg_upgrade --check

- Helper 19 cluster: UTF8, libc `en_US.UTF-8`, checksums on (as in 18). `--check` with PG18 running, ports 5432/5434.
- **copy and link: `*Clusters are compatible*`**, every check `ok` (including the new ones: `gist_inet_ops/gist_cidr_ops`,
  `objects affected by Unicode update`, `not-null constraint inconsistencies`) → `../results/upgrade_check_*_full/check_*.txt`.
- **What it does not say:** the cluster holds only `postgres` (table `fakty`) and `labtest`, no extensions or custom types.
  A cluster with `btree_gist`, `pg_trgm`, `postgis` or MD5 passwords is a different story — always run `pg_upgrade --check`
  on a copy of production.

## ⚖️ Conditions and limits

- One VM (4 vCPUs, 3.6 GB RAM, virtual NVMe on a laptop SSD). Absolute numbers describe this machine; what carries over is
  the **ratio and the shape** (where writes stall).
- Only the versions and their defaults differ ([RUN §3](RUN.md#3-environment-card)); `jit` aligned in F.
- Run-to-run spread: R ≤ 5% of operation time (part 1), F ≤ 7%.
- The write load in R is a synthetic one-row `UPDATE` by PK; an application with longer transactions would wait differently,
  especially in the final phase of REPACK.
