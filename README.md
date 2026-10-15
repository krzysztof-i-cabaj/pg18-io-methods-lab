# 🐘 pg18-io-methods-lab — PostgreSQL 18 asynchronous I/O: sync vs worker vs io_uring

[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-18.6-336791?logo=postgresql&logoColor=white)]()
[![OS](https://img.shields.io/badge/Rocky_Linux-9.8-orange)]()
[![Method](https://img.shields.io/badge/Plan_check-every_run-success)]()
[![Paths](https://img.shields.io/badge/Install-scripted_%7C_manual-blueviolet)]()
[![License](https://img.shields.io/badge/License-MIT-F1C40F)](LICENSE)

> 🎯 One VM, one 13 GB table, the same queries — only `io_method` changes. Every measurement re-checks the execution plan,
> so a result is reported only for the plan the test is named after. 🇵🇱 [Wersja polska](README_PL.md)

**Interactive report:** <https://krzysztof-i-cabaj.github.io/pg18-io-methods-lab/> · Markdown: [docs/RESULTS.md](docs/RESULTS.md)

## 📊 Results

Cold cache, median of 7 interleaved series (main run, data disk on an emulated SATA controller) and of 3 series
(control run, the same disk moved to an emulated NVMe controller). Lower is faster; ratios are relative to `sync`.

| Test | `sync` | `worker` | `io_uring` | Control run on NVMe: `sync` / `worker` / `io_uring` |
|---|---:|---:|---:|---:|
| T1a · Seq Scan | 59.1 s | 58.4 s (≈ sync) | **54.2 s** (1.09× faster) | — |
| T1b · Parallel Seq Scan | 41.8 s | 57.8 s (1.38× slower) | **34.5 s** (1.21× faster) | **43.5 s** / 58.4 s / 66.0 s |
| T2 · Bitmap Heap Scan | **11.0 s** | 22.5 s (2.05× slower) | 16.8 s (1.53× slower) | **5.9 s** / 15.3 s / 11.7 s |
| T3 · Index Scan | 3.34 s | 3.51 s | 3.35 s | — |
| T4 · VACUUM | **15.2 s** | 21.4 s (1.41× slower) | 18.2 s (1.20× slower) | **10.8 s** / 16.7 s / 14.2 s |

- **`sync` was fastest for Bitmap Heap Scan and VACUUM on both disk controllers.**
- **The io_uring gain on full scans depended on the controller:** 1.21× faster on SATA, 1.52× slower on NVMe for the parallel scan.
- **`worker` (the PostgreSQL 18 default) was never faster than `sync` on cold data** with the default `io_workers = 3`.
- Index Scan does not use asynchronous I/O in PostgreSQL 18; warm-cache differences are within noise.

![Overview](docs/charts/overview_en.svg)
![Control run](docs/charts/control_nvme_en.svg)

Every number, chart and the raw CSV: [docs/RESULTS.md](docs/RESULTS.md) · [interactive report](https://krzysztof-i-cabaj.github.io/pg18-io-methods-lab/).

## 🎯 Goal

Measure what PostgreSQL 18 asynchronous I/O (`io_method = worker` and `io_uring`) changes compared with synchronous reads
(`sync`) for the access paths a DBA meets every day — full scan, parallel scan, bitmap heap scan, index scan and VACUUM —
with a cold and a warm cache, changing **one variable only**.

## 🧭 Scope

| In scope | Out of scope |
|---|---|
| One VM built from scratch (kickstart or manual install), PostgreSQL 18 from PGDG | Bare-metal servers, cloud storage, network disks |
| Deterministic test data (100 M rows), plan check, interleaved series, report generator | Comparing PostgreSQL versions (16/17 vs 18) |
| `io_method` ∈ {`sync`, `worker`, `io_uring`} with default `io_workers` / `effective_io_concurrency` | Tuning sweeps of `io_workers`, `effective_io_concurrency`, `io_combine_limit` |

## 🧪 What is measured

| Test | Query / operation | Plan node (checked every run) | Cache |
|---|---|---|---|
| T1a | `count(*), avg(v)` over the whole table, no parallelism | `Seq Scan` | cold |
| T1b | the same with parallel workers | `Parallel Seq Scan` | cold |
| T2 | one day of data (~54 k rows scattered over the table) | `Bitmap Heap Scan` | cold, warm |
| T3 | 5,000 rows in index order of a random key | `Index Scan` | cold, warm |
| T4 | `VACUUM` of a 10 M-row copy after deleting 10 % | — (same work verified: 1,000,000 removed tuples) | cold |

Cold = PostgreSQL stopped, OS page cache dropped, PostgreSQL started before **every** measurement.
7 series, modes interleaved (`sync → worker → io_uring` → …). Details: [docs/METHODOLOGY.md](docs/METHODOLOGY.md).

## 📁 Structure

```text
.
├── lab.ps1, lab.config.psd1      # scripted path: one verb per stage (plan, build, provision, …)
├── host/                         # PowerShell modules for VirtualBox + kickstart HTTP server
├── kickstart/pgio.ks.tmpl        # unattended Rocky Linux install (template, no secrets)
├── guest/                        # provision.sh (PostgreSQL 18), env_card.sh (environment card)
├── sql/01_create_test_data.sql   # 100 M-row test table
├── bench/                        # tests.conf, plan_check.sh, run_bench.sh
├── report/make_report.py         # CSV → RESULTS.md, SVG charts, GitHub Pages
├── results/                      # raw CSV, JSON plans, logs, environment card; control_nvme/ = control run
└── docs/                         # INSTALL, METHODOLOGY, RESULTS (EN + PL), GitHub Pages site
```

## 📋 Requirements

Windows 11 + PowerShell 7 (scripted path) or any VirtualBox host (manual path) · VirtualBox 7.x · Python 3.8+ ·
OpenSSH key pair · `Rocky-9.8-x86_64-minimal.iso` · ~80 GB free disk · host-only network `192.168.56.0/24`.

## 🚀 Run

Every stage has two paths: 🤖 **scripted (automatic / semi-automatic)** and ✋ **manual** (plain `VBoxManage`, installer, `dnf`, `psql`).
Full instructions for both: [docs/INSTALL.md](docs/INSTALL.md).

| # | Stage | 🤖 Scripted path | ✋ Manual path |
|---|---|---|---|
| 1 | Host check | `.\lab.ps1 plan` | [INSTALL §2](docs/INSTALL.md#️-2-host-configuration) |
| 2 | VM + Rocky Linux 9.8 | `.\lab.ps1 build` | [INSTALL §3](docs/INSTALL.md#️-3-build-the-vm) |
| 3 | PostgreSQL 18 | `.\lab.ps1 provision -DryRun`, then `provision` | [INSTALL §4](docs/INSTALL.md#-4-install-postgresql-18) |
| 4 | Environment card | `.\lab.ps1 envcard` | [INSTALL §5](docs/INSTALL.md#-5-environment-card) |
| 5 | Test data (~15 min) | `.\lab.ps1 loaddata` | [INSTALL §6](docs/INSTALL.md#-6-test-data) |
| 6 | Plan check | `.\lab.ps1 plans` | [INSTALL §7](docs/INSTALL.md#-7-plan-check-explain-only) |
| 7 | Measurements (~85 min) | `.\lab.ps1 bench 7`, then `fetch` | [INSTALL §8](docs/INSTALL.md#️-8-measurements) |
| 8 | Report | `python report\make_report.py` | [INSTALL §9](docs/INSTALL.md#-9-report) |

## ✅ Verification

- `.\lab.ps1 plans` → **PASS** for T1a, T1b, T2, T3 before measuring.
- `results/raw_*.csv` → every row `plan_ok = 1`; VACUUM rows report the same work in every mode.
- `python report\make_report.py --dry-run` → medians on screen, `rejected = 0`.

## ↩️ Rollback

`.\lab.ps1 destroy pgio` (or `VBoxManage unregistervm pgio --delete`) removes the VM and its disks.
The host-only adapter, the ISO and the firewall rule stay; remove the rule with `Remove-NetFirewallRule -DisplayName 'pgio-lab-ks-8000'`.

## ⚠️ Notes and limits

- **These numbers describe one environment:** a VirtualBox VM (4 vCPUs, 3.6 GB RAM) on a laptop with a Samsung 990 PRO NVMe,
  host I/O cache off. The control run shows that the emulated storage stack alone can reverse a result — test on your own hardware.
- PostgreSQL 18 defaults only (`io_workers = 3`, `effective_io_concurrency = 16`, `io_combine_limit = 128kB`); tuning them is the next step.
- RHEL/Rocky 9 disable io_uring in the kernel (`kernel.io_uring_disabled = 2`); the lab sets it to `0`. Without it `io_method = io_uring` does not start.
- No other VM may run during measurements (shared host disk); `lab.ps1 plan` checks this.
- Data disk is **fixed-size** and the host I/O cache is **off** — otherwise a "cold cache" inside the guest is served from host RAM.

## 🔐 Security

No passwords anywhere: root is locked in the kickstart, access is by your SSH public key only, PostgreSQL listens on `localhost`.
The rendered `kickstart/pgio.ks` (contains your public key) is git-ignored; only the template is in the repository.

## 👤 Author

Krzysztof Cabaj · KCB Consulting · License: [MIT](LICENSE)
