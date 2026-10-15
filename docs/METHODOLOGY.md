# 🧪 Methodology

[![Variable](https://img.shields.io/badge/Variable-io__method_only-blue)]()
[![Series](https://img.shields.io/badge/Series-7_interleaved-blueviolet)]()
[![Guard](https://img.shields.io/badge/Plan_guard-every_measurement-success)]()

> 🎯 How the numbers in this repository were produced, and what they can and cannot tell you.
> 🇵🇱 [Wersja polska](METHODOLOGY_PL.md)

---

## 🎯 Question

How does `io_method` in PostgreSQL 18 — `sync`, `worker`, `io_uring` — affect read-heavy operations on data that
does **not** fit in memory, on the same VM, the same build, the same data and the same configuration?

## 🔒 What is held constant

| Item | Value |
|---|---|
| Binary | PostgreSQL 18.6 (PGDG), built `--with-liburing` |
| Data | table `fakty`, 100 M rows, 13 GB heap + 4.9 GB indexes, generated with `setseed(0.42)` |
| Configuration | `shared_buffers = 1GB`, `track_io_timing = on`, all `io_*` and `*_io_concurrency` at PG18 defaults |
| VM | 4 vCPU, 3.6 GB RAM, data on a fixed-size VDI, host I/O cache off, no other VM running |
| Table | `autovacuum_enabled = off` for the duration of the run (static data) |

**The only change between modes:** `ALTER SYSTEM SET io_method = …` followed by a restart.

## 📐 Tests

Defined in [`bench/tests.conf`](../bench/tests.conf). Each test declares the plan node it is meant to measure.

| Test | Query | Expected node | Data touched |
|---|---|---|---|
| T1a | `count(*), avg(v)` over the whole table, `max_parallel_workers_per_gather = 0` | `Seq Scan` | 13 GB sequential |
| T1b | same, default parallelism | `Parallel Seq Scan` | 13 GB sequential, 3 processes |
| T2 | one day of `d` (~54.5 k rows), no parallelism | `Bitmap Heap Scan` | ~54 k pages scattered over 13 GB |
| T3 | 5 000 consecutive values of `r` via `ORDER BY r LIMIT 5000` | `Index Scan` | ~5 k random heap pages |
| T4 | `VACUUM (VERBOSE)` of a 10 M-row copy after deleting 10 % | — | ~1.3 GB table + index |

T2 uses a single day because, with this data and `random_page_cost = 4`, the planner picks `Bitmap Heap Scan`
naturally only for that range (3–14 days → `Index Scan`, ≥ 30 days → `Seq Scan`). No planner settings are forced.

## 🛡️ Plan guard

Every measurement runs `EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, FORMAT JSON)` and checks that the expected node is in the
executed plan. The result is stored with `plan_ok = 0/1`; **rows with `plan_ok = 0` are excluded from the report**.
The executed plans of the first series are kept in `results/plans_*/`.

## ❄️ Cold and 🔥 warm cache

- **Cold:** before every single measurement — stop PostgreSQL, `sync`, `echo 3 > /proc/sys/vm/drop_caches`, start PostgreSQL.
  With the VirtualBox host I/O cache disabled, reads really go to the host NVMe.
- **Warm:** one unmeasured warm-up execution, then the measured one. Only for **T2 and T3**, whose pages fit in memory.
  For T1 the 13 GB table is 3.6× the VM RAM; in a trial run a "warm" `Seq Scan` took 53.7 s vs 58.9 s cold, so a warm
  full scan is effectively a cold one and was not measured separately.
- **T4 (VACUUM):** cold only; the table is recreated identically (`CREATE TABLE AS`, index, `DELETE` 10 %, `CHECKPOINT`) before every run.

## 🔁 Series

7 series. Within each series the modes run in the order `sync → worker → io_uring`, so any drift of the host over
time (thermal, background activity) is spread across all modes instead of hitting one of them.

## 📊 Reported values

Per test × cache × mode: **median**, min and max of the execution time over 7 series, plus the median of
`Shared Read Blocks` and of the I/O read time reported by `track_io_timing`. Speed-ups are ratios of medians relative to `sync`.

Raw data: `results/raw_20261015_152307.csv` (main run). In this file the `exec_ms` column of the **T4 rows holds microseconds**
(written by `run_bench.sh` 1.0); the report converts them, and `run_bench.sh` 1.1 writes milliseconds.

## 🔁 Control run — data disk on an NVMe controller

The main run showed `sync` ahead of asynchronous I/O for bitmap heap scans and VACUUM. Before publishing, one variable was
changed to check whether the emulated SATA (AHCI) controller causes it: the **data disk** was moved to an emulated **NVMe**
controller (`useHostIOCache=false`, non-rotational). OS disk, data, PostgreSQL settings and queries stayed the same; in the guest
`/pgdata` is mounted by label, so the new device name (`nvme0n1`) changes nothing. Scheduler stayed `mq-deadline`;
the queue depth seen by the guest (`nr_requests`) is 256 on NVMe vs 64 on SATA — part of the controller change.

Scope: T1b, T2, T4, cold cache, 3 interleaved series (27 measurements, 0 rejected) — `results/control_nvme/`.
Result: `sync` stayed fastest for T2 and T4; the io_uring advantage on T1b reversed (1.21× faster on SATA, 1.52× slower on NVMe).

## ⚠️ Limitations

- A single VM on a laptop host (VirtualBox, virtual SATA on top of NVMe) — absolute numbers are **not** representative of
  production storage; compare modes with each other, not with other systems.
- `EXPLAIN ANALYZE` adds small overhead (timing per node is switched off to keep it minimal).
- `io_uring` required changing a kernel default (`kernel.io_uring_disabled = 0`); RHEL/Rocky 9 disable it out of the box.
- PG18 defaults only (`io_workers = 3`, `effective_io_concurrency = 16`, `io_combine_limit = 128kB`); tuning was out of scope.
