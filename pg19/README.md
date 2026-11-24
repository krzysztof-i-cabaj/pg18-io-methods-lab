# 🐘 pg19 — PostgreSQL 19 vs 18 on the same VM: REPACK (CONCURRENTLY), foreign keys, pg_upgrade --check

[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-18.6_%E2%86%92_19.0-336791?logo=postgresql&logoColor=white)]()
[![OS](https://img.shields.io/badge/Rocky_Linux-9.8-orange)]()
[![VM](https://img.shields.io/badge/VM-pgio_(this_repo)-blue)](../README.md)
[![Runs](https://img.shields.io/badge/Runs-R_27_%C2%B7_F_20_%C2%B7_U_ok-success)]()
[![License](https://img.shields.io/badge/License-MIT-F1C40F)](../LICENSE)

> 🎯 A follow-up on the `pgio` VM from this repository: PostgreSQL 19.0 installed next to 18.6 on the same disk, and three
> claims from the PostgreSQL 19 release checked by measurement. 🇵🇱 [Wersja polska](README_PL.md)

**Interactive page (REPACK):** <https://krzysztof-i-cabaj.github.io/pg18-io-methods-lab/pg19/> ·
Markdown: [docs/RESULTS.md](docs/RESULTS.md) · step by step: [docs/RUN.md](docs/RUN.md)

## 📊 Results

**R · REPACK (CONCURRENTLY) vs VACUUM FULL.** A 2.3 GB table (20 M rows, half deleted) is rewritten while 1, 4 or 8
`pgbench` sessions keep updating it. "Writes stalled" = seconds with 0 transactions; median of 3 runs, PostgreSQL 19.0.

| Writing sessions | `VACUUM FULL`: writes stalled | `REPACK (CONCURRENTLY)`: writes stalled | REPACK duration | Longest wait VF / REPACK |
|---|---:|---:|---:|---:|
| 1 (~1,700–1,900 tps) | 11 s | **0 s** | 13.6 s | 12.3 s / **0.1 s** |
| 4 (~5,700 tps) | 13 s | **5 s** | 32.5 s | 13.7 s / 6.1 s |
| 8 (~7,600–9,400 tps) | **15 s** (15–21) | 18 s (18–19) | 93.1 s | 16.1 s / 19.6 s |

- **REPACK (CONCURRENTLY) is not "zero downtime":** writes continue during the copy, but the final phase takes
  `ACCESS EXCLUSIVE` and its length grows with traffic: 0 → 5 → 18 s. The documentation says the lock is held
  "typically for a short time, depending on the amount of changes"; this is what "short" meant here.
- **With 8 sessions REPACK stalled writes longer than VACUUM FULL** (18 s vs 15 s). The 4 vCPUs were saturated, so read
  it as "comparable or worse", not as an exact difference.
- **The version alone does not change the old command:** `VACUUM FULL` in 18 and 19 blocks the same way (14 vs 13 s).

**F · foreign key check on bulk INSERT** (5 M rows into a table with an FK to a 100 k-row parent, 5 runs):
PG18 **27.6 s** → PG19 **14.4 s** = **1.92×** faster; the FK part alone 2.36× (22.6 s → 9.6 s). Without the FK both
versions are equal (5.0 vs 4.9 s). The release says "nearly 2×" — confirmed for this scenario.

**U · `pg_upgrade --check` 18 → 19** (copy and link): `*Clusters are compatible*`, all checks `ok` — for a simple
cluster without extensions.

## 🎯 Goal

Check three PostgreSQL 19 release claims on our own hardware instead of repeating the feature list:
non-blocking `REPACK (CONCURRENTLY)`, "nearly 2×" faster foreign key checks, and what `pg_upgrade --check` says about
the PostgreSQL 18 cluster from the main lab. Only the server version (or the command) changes; VM, disk and
configuration stay the same.

## 🧭 Scope

| In scope | Out of scope |
|---|---|
| PG19 from PGDG next to PG18 on VM `pgio` (port 5433, `/pgdata/19/data`, same settings) | Replication features (`WAIT FOR LSN`, sequences in logical replication) |
| R: `VACUUM FULL` (18, 19) vs `REPACK (CONCURRENTLY)` (19) under 1/4/8 writing sessions | Planner changes, PG19 `io_method` defaults |
| F: `INSERT … SELECT` 5 M rows with and without an FK, `jit = off` in both | Tables with indexes, WAL shipping, application triggers |
| U: `pg_upgrade --check` (copy and link) from the 18 cluster | A real upgrade; clusters with extensions |

## 📁 Structure

```text
pg19/
├── lab.ps1                  # host driver: status, start, install, preflight, push, trial, run, progress, fetch, stop
├── guest/
│   ├── preflight.sh         # environment card (read-only)
│   └── install_pg19.sh      # PG19 from PGDG next to PG18 (DRY_RUN=1 = preview)
├── bench/
│   ├── run_all.sh           # orchestration: SUITE=all|repack|fk|upgrade|clients, TRIAL=1, DRY_RUN=1
│   ├── repack_test.sh       # test R (+ per-second tps timeline)
│   ├── writer.sql           # pgbench writer: UPDATE of a random row by PK
│   ├── fk_test.sh           # test F
│   ├── upgrade_check.sh     # test U
│   └── common.sh            # cluster selection, cold restart
├── sql/                     # 10_bloat_table.sql (R), 20_fk_tables.sql (F)
├── report/                  # summarize.py, timeline_stats.py, build_explainer.py + page templates (PL, EN)
├── results/                 # raw CSV, timelines, plans, environment card, run.log, SUMMARY_*.md
└── docs/                    # RESULTS, RUN (EN + PL)
```

The interactive page is built into [`../docs/pg19/`](../docs/pg19/) (GitHub Pages).

## 📋 Requirements

The `pgio` VM built and provisioned with the main lab ([README](../README.md), stages 1–3): Rocky Linux 9.8,
PostgreSQL 18.6, data disk on `/pgdata`. Plus: internet access from the VM (PGDG packages), ≥ 12 GB free on `/pgdata`,
Windows 11 + PowerShell 7 + OpenSSH key (scripted path), Python 3.8+ for the reports.

## 🚀 Run

Every stage has two paths: 🤖 **scripted** (`lab.ps1`, from the `pg19` directory) and ✋ **manual** (`ssh`, `scp`, `dnf`, `psql`).
Both are described in [docs/RUN.md](docs/RUN.md).

| # | Stage | 🤖 Scripted path | ✋ Manual path |
|---|---|---|---|
| 1 | VM up | `.\lab.ps1 status`, `.\lab.ps1 start` | [RUN §1](docs/RUN.md#1-start-the-vm) |
| 2 | PostgreSQL 19 next to 18 | `.\lab.ps1 install -DryRun`, then `install` | [RUN §2](docs/RUN.md#2-install-postgresql-19-next-to-18) |
| 3 | Environment card | `.\lab.ps1 preflight` | [RUN §3](docs/RUN.md#3-environment-card) |
| 4 | Scripts to the VM | `.\lab.ps1 push` | [RUN §4](docs/RUN.md#4-copy-the-scripts) |
| 5 | Trial (small tables, ~1 min) | `.\lab.ps1 trial`, `progress`, `fetch` | [RUN §5](docs/RUN.md#5-trial) |
| 6 | Part 1: R, F, U (~30 min) | `.\lab.ps1 run`, `progress`, `fetch` | [RUN §6](docs/RUN.md#6-part-1-r-f-u) |
| 7 | Part 2: REPACK at 1/4/8 sessions (~26 min) | `.\lab.ps1 run -Suite clients -RunsR 3` | [RUN §7](docs/RUN.md#7-part-2-repack-at-148-sessions) |
| 8 | Control: VACUUM FULL at 1/8 sessions (~16 min) | `.\lab.ps1 run -Suite clients -RunsR 3 -ExtraEnv 'VARIANT_C=vacuum_full CLIENTS_LIST=1,8'` | [RUN §8](docs/RUN.md#8-control-vacuum-full-at-1-and-8-sessions) |
| 9 | Report and page | `python report\summarize.py`, `python report\build_explainer.py …` | [RUN §9](docs/RUN.md#9-report-and-page) |

## ✅ Verification

- `run.log` ends with `KONIEC suite=… fail=0` (`KONIEC` = end); every CSV row has `ok=1`.
- R: the table after the operation holds half of the rows; F: the target table holds `ROWS_F` rows.
- `python report\summarize.py --ts <ts>` reports `Odrzucone serie (ok=0): 0` (rejected runs: 0).

## ↩️ Rollback

- Test data: `DROP DATABASE labtest` in both clusters (the main lab table `fakty` lives in `postgres` and is not touched).
- PostgreSQL 19: `systemctl stop postgresql-19; dnf -y remove postgresql19-server postgresql19-contrib postgresql19 postgresql19-libs;
  rm -rf /pgdata/19 /etc/systemd/system/postgresql-19.service.d; systemctl daemon-reload`. PG18 is back to its previous state.

## ⚠️ Notes and limits

- **One VM** (4 vCPUs, 3.6 GB RAM, virtual NVMe on a laptop SSD). Absolute seconds describe this machine; what carries
  over is the shape — where writes stall and how that grows with traffic.
- The load in R is a synthetic one-row `UPDATE` by primary key. An application with longer transactions would wait differently,
  especially in the final phase of REPACK.
- From the documentation, not visible in the numbers: `REPACK (CONCURRENTLY)` is **not MVCC-safe** (`VACUUM FULL` is),
  it needs a primary key or a replica identity index, uses a slot from `max_repack_replication_slots` (default 5) and aborts
  above ~104 M concurrent changes.
- Script comments and console messages are bilingual or Polish (as in the main lab); the documentation is in English and Polish.
- Defaults that differ between 18 and 19 on this VM (`jit`, `io_workers`, `log_lock_waits`, …): [RUN §3](docs/RUN.md#3-environment-card).

## 🔗 Sources

[PostgreSQL 19 Released!](https://postgresql.org/about/news/postgresql-19-released-3449) ·
[Release notes 19](https://www.postgresql.org/docs/19/release-19.html) ·
[REPACK](https://www.postgresql.org/docs/19/sql-repack.html) ·
[pg_upgrade](https://www.postgresql.org/docs/19/pgupgrade.html)

## 👤 Author

Krzysztof Cabaj · KCB Consulting · the lab was built and measured with Claude Code (Agentic DBA Lab #7) ·
License: [MIT](../LICENSE)
