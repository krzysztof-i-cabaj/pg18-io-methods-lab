# 📊 Results — PostgreSQL 18 io_method: sync vs worker vs io_uring

[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-18.6-336791)]() [![io_method](https://img.shields.io/badge/io__method-sync_%7C_worker_%7C_io__uring-blue)]() [![Runs](https://img.shields.io/badge/Series-7_interleaved-success)]() [![Plans](https://img.shields.io/badge/Plan_check-every_run-success)]()

> 🎯 Measured medians for every test, cache state and `io_method`, generated from the raw CSV by `report/make_report.py`. Polish version: [RESULTS_PL.md](RESULTS_PL.md) · interactive page: [GitHub Pages](https://krzysztof-i-cabaj.github.io/pg18-io-methods-lab/).

Source: `results/raw_20261015_152307.csv` · 147 accepted measurements · 0 rejected (plan check)

## 🔎 Key findings

- **Bitmap Heap Scan and VACUUM were fastest with `sync` — on both disk controllers.** Main run (SATA): bitmap heap scan `sync` 11.0 s, `io_uring` 1.53× slower, `worker` 2.05× slower; VACUUM `sync` 15.2 s, `io_uring` 1.20×, `worker` 1.41× slower. Control run (NVMe): the same order with larger gaps — bitmap 5.9 s vs 1.98× and 2.58× slower, VACUUM 10.8 s vs 1.31× and 1.54× slower. Every mode reads the same 53,866 blocks and VACUUM does the same work (1,000,000 removed tuples, 163,935 frozen pages).
- **The io_uring gain on full scans depends on the virtual disk controller.** On SATA io_uring was the fastest: `Seq Scan` 1.09× and `Parallel Seq Scan` 1.21× faster than `sync`. On NVMe the parallel scan with io_uring took 66.0 s — 1.52× **slower** than `sync` (43.5 s). Do not read the SATA result as a general property of io_uring.
- **`worker` was never faster than `sync` on cold data.** It matched `sync` on the single-process scan (58.4 vs 59.1 s) and was slower everywhere else, with the defaults `io_workers = 3` on 4 vCPUs.
- **Index Scan does not change** (3.3–3.5 s): in PostgreSQL 18 asynchronous I/O covers sequential scans, bitmap heap scans and VACUUM ([release notes](https://www.postgresql.org/docs/18/release-18.html)); an index scan reads heap pages one at a time.
- **Warm cache shows no real difference.** T2 63–71 ms, T3 4.5–6.1 ms with 0 blocks read from disk; the spread between runs (up to 22 %) is larger than the gaps between modes.
- **The numbers are stable.** Main run: 7 interleaved series, coefficient of variation 0.5–2.8 % (T3 `worker` 9 %). Control run: 3 series, max–min within 3 % except one `sync` parallel scan (52.3 s vs 43.4–43.5 s).
- **What this does not say.** It is one VirtualBox VM (4 vCPUs, 3.6 GB RAM, host I/O cache off) with PostgreSQL defaults `io_workers = 3`, `effective_io_concurrency = 16`. The second run shows that the emulated storage stack changes the picture, so these numbers describe this environment, not your server. Next variables to test, one at a time: `effective_io_concurrency`, `io_workers`, bare-metal storage.

## 🧭 Overview — main run (SATA controller)

![chart](charts/overview_en.svg)

## 🔁 Control run: data disk on an NVMe controller

*one variable changed: the VM's virtual disk controller (SATA/AHCI → NVMe); 3 series, cold cache*

![chart](charts/control_nvme_en.svg)

Same VM, data, PostgreSQL settings and queries; only the data disk was moved from the emulated SATA (AHCI) controller to an emulated NVMe controller (host I/O cache off on both). Source: `results/control_nvme/raw_20261015_164202.csv` · 27 measurements · 0 rejected.

| Test | io_method | SATA median | NVMe median | SATA vs sync | NVMe vs sync |
|---|---|---:|---:|---:|---:|
| T1b | `sync` | 41.8 s | 43.5 s (n=3) | baseline | baseline |
| T1b | `worker` | 57.8 s | 58.4 s (n=3) | 1.38× slower | 1.34× slower |
| T1b | `io_uring` | 34.5 s | 66.0 s (n=3) | 1.21× faster | 1.52× slower |
| T2 | `sync` | 11.0 s | 5.91 s (n=3) | baseline | baseline |
| T2 | `worker` | 22.5 s | 15.3 s (n=3) | 2.05× slower | 2.58× slower |
| T2 | `io_uring` | 16.8 s | 11.7 s (n=3) | 1.53× slower | 1.98× slower |
| T4 | `sync` | 15.2 s | 10.8 s (n=3) | baseline | baseline |
| T4 | `worker` | 21.4 s | 16.7 s (n=3) | 1.41× slower | 1.54× slower |
| T4 | `io_uring` | 18.2 s | 14.2 s (n=3) | 1.20× slower | 1.31× slower |

## 🧊 Cold cache — main run (PostgreSQL restarted, OS page cache dropped before every run)

![T1a · Seq Scan, 1 process — cold cache](charts/T1a_cold_en.svg)

![T1b · Parallel Seq Scan, 2 workers — cold cache](charts/T1b_cold_en.svg)

![T2 · Bitmap Heap Scan, 1 day (~54k rows) — cold cache](charts/T2_cold_en.svg)

![T3 · Index Scan, 5,000 rows — cold cache](charts/T3_cold_en.svg)

![T4 · VACUUM, 10M rows, 10% deleted — cold cache](charts/T4_cold_en.svg)

## 🔥 Warm cache — main run (data already in shared_buffers)

![T2 · Bitmap Heap Scan, 1 day (~54k rows) — warm cache](charts/T2_warm_en.svg)

![T3 · Index Scan, 5,000 rows — warm cache](charts/T3_warm_en.svg)

## 📋 All numbers

Median, min, max and p90 of 7 interleaved series. *vs sync* = ratio of medians. *I/O read* = median of `I/O Timings: shared read` from `EXPLAIN (ANALYZE, BUFFERS)`; with parallel workers or asynchronous I/O it sums waits across processes and is not wall-clock time.

| Test | Cache | io_method | n | Median | Min | Max | p90 | vs sync | I/O read |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| T1a | cold cache | `sync` | 7 | 59.1 s | 58.2 s | 61.4 s | 61.4 s | baseline | 51.6 s |
| T1a | cold cache | `worker` | 7 | 58.4 s | 57.2 s | 59.1 s | 59.1 s | ≈ sync | 30.7 s |
| T1a | cold cache | `io_uring` | 7 | 54.2 s | 53.4 s | 55.0 s | 55.0 s | 1.09× faster | 15.6 s |
| T1b | cold cache | `sync` | 7 | 41.8 s | 41.2 s | 42.0 s | 42.0 s | baseline | 111.0 s |
| T1b | cold cache | `worker` | 7 | 57.8 s | 57.5 s | 60.1 s | 60.1 s | 1.38× slower | 144.1 s |
| T1b | cold cache | `io_uring` | 7 | 34.5 s | 34.2 s | 34.9 s | 34.9 s | 1.21× faster | 71.0 s |
| T2 | cold cache | `sync` | 7 | 11.0 s | 10.8 s | 11.4 s | 11.4 s | baseline | 3.08 s |
| T2 | cold cache | `worker` | 7 | 22.5 s | 22.3 s | 22.9 s | 22.9 s | 2.05× slower | 21.0 s |
| T2 | cold cache | `io_uring` | 7 | 16.8 s | 16.6 s | 16.9 s | 16.9 s | 1.53× slower | 14.4 s |
| T3 | cold cache | `sync` | 7 | 3.34 s | 3.24 s | 3.49 s | 3.49 s | baseline | 3.32 s |
| T3 | cold cache | `worker` | 7 | 3.51 s | 3.23 s | 4.13 s | 4.13 s | 1.05× slower | 3.49 s |
| T3 | cold cache | `io_uring` | 7 | 3.35 s | 3.23 s | 3.52 s | 3.52 s | ≈ sync | 3.33 s |
| T4 | cold cache | `sync` | 7 | 15.2 s | 15.0 s | 16.2 s | 16.2 s | baseline | — |
| T4 | cold cache | `worker` | 7 | 21.4 s | 20.9 s | 22.0 s | 22.0 s | 1.41× slower | — |
| T4 | cold cache | `io_uring` | 7 | 18.2 s | 18.0 s | 18.5 s | 18.5 s | 1.20× slower | — |
| T2 | warm cache | `sync` | 7 | 67.4 ms | 59.0 ms | 71.9 ms | 71.9 ms | baseline | 0.0 ms |
| T2 | warm cache | `worker` | 7 | 63.4 ms | 56.5 ms | 68.5 ms | 68.5 ms | 1.06× faster | 0.0 ms |
| T2 | warm cache | `io_uring` | 7 | 70.9 ms | 61.1 ms | 81.4 ms | 81.4 ms | 1.05× slower | 0.0 ms |
| T3 | warm cache | `sync` | 7 | 6.1 ms | 4.1 ms | 6.9 ms | 6.9 ms | baseline | 0.0 ms |
| T3 | warm cache | `worker` | 7 | 4.5 ms | 3.6 ms | 6.6 ms | 6.6 ms | 1.35× faster | 0.0 ms |
| T3 | warm cache | `io_uring` | 7 | 5.7 ms | 4.9 ms | 6.5 ms | 6.5 ms | 1.06× faster | 0.0 ms |

## 🖥️ Environment

| | |
|---|---|
| **PostgreSQL** | PostgreSQL 18.6 |
| **OS** | Rocky Linux release 9.8, kernel 5.14.0-687.57.1.el9_8.x86_64 |
| **CPU** | AMD Ryzen 9 8940HX with Radeon Graphics · 4 vCPU |
| **RAM** | 3.6 GB · shared_buffers 1 GB |
| **Storage** | ? · VirtualBox ? · host I/O cache off |
| **I/O** | effective_io_concurrency 16 · io_workers 3 · io_combine_limit 128 kB |
| **Data** | fakty: 100 M rows, 13 GB + 4.9 GB indexes |

## 🔗 Method

How the tests were chosen and run: [METHODOLOGY.md](METHODOLOGY.md) · how to reproduce: [INSTALL.md](INSTALL.md) · raw data: [`results/`](../results/).

---

© KCB Consulting · Krzysztof Cabaj · generated 2026-10-15
