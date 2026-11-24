# 📗 RUN — PostgreSQL 19 vs 18, step by step (scripted and manual)

[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-18.6_%2B_19.0-336791)]()
[![VM](https://img.shields.io/badge/VM-pgio_NVMe-orange)]()
[![Paths](https://img.shields.io/badge/Paths-scripted_%7C_manual-blueviolet)]()
[![Run](https://img.shields.io/badge/Measured-2026--11--23-success)]()

> 🎯 Every step: the 🤖 scripted command, the ✋ manual equivalent, why it is there and what came out in our run
> (23 Nov 2026). 🇵🇱 [Wersja polska](RUN_PL.md) · results and interpretation: [RESULTS.md](RESULTS.md)

Scripted commands run in PowerShell 7 from the `pg19` directory of this repository. Manual commands assume the VM from the
main lab: `pgio`, `192.168.56.40`, root login with your SSH key. On the VM the lab lives in `/root/pg19lab`.

## 🧭 Decisions before the start

| Decision | Choice | Why |
|---|---|---|
| Data disk controller | **NVMe** (as after the main lab's control run) | nothing rebuilt = one difference less; for 18 vs 19 only "the same controller" matters |
| PG19 on the same VM | yes, next to PG18 (port 5433, `/pgdata/19/data`) | same hardware, OS and disk — only the server version differs |
| Host idle | no other VMs, no recordings | they disturb I/O; `lab.ps1 start` refuses when other VMs run (`-Force` overrides) |

## 1. Start the VM

- 🤖 `.\lab.ps1 status`, then `.\lab.ps1 start` (headless start, waits for SSH, prints the disk controllers).
- ✋ `& 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe' startvm pgio --type headless`, then `ssh root@192.168.56.40 hostname`.
- **Our run:** controllers `SATA` (system) and `NVMe` (data disk), SSH answers.

## 2. Install PostgreSQL 19 next to 18

- 🤖 `.\lab.ps1 install -DryRun` (preview: free space ≥ 12 GB, PG18 running, port 5433 free, the plan), then `.\lab.ps1 install`.
  The script `guest/install_pg19.sh` goes to the VM over SSH stdin and does not stay there.
- ✋ On the VM as root:

  ```bash
  dnf -y install https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
  dnf -y install postgresql19-server postgresql19-contrib
  mkdir -p /pgdata/19/data && chown -R postgres:postgres /pgdata/19 && chmod 700 /pgdata/19/data && restorecon -R /pgdata/19
  mkdir -p /etc/systemd/system/postgresql-19.service.d
  printf '[Service]\nEnvironment=PGDATA=/pgdata/19/data\n' > /etc/systemd/system/postgresql-19.service.d/pgdata.conf
  systemctl daemon-reload
  PGSETUP_INITDB_OPTIONS='--data-checksums' /usr/pgsql-19/bin/postgresql-19-setup initdb
  mkdir -p /pgdata/19/data/conf.d && echo "include_dir = 'conf.d'" >> /pgdata/19/data/postgresql.conf
  printf "listen_addresses = 'localhost'\nport = 5433\nshared_buffers = '1GB'\ntrack_io_timing = on\n" > /pgdata/19/data/conf.d/10-lab.conf
  chown -R postgres:postgres /pgdata/19/data/conf.d
  systemctl start postgresql-19          # no "enable": only PG18 starts at boot
  ```

- **Our run:** the PGDG repo package from October did not know PG19 yet (`42.0-70`); installing it from the URL upgraded it
  to `42.0-71`. Installed `postgresql19-*-19.0-1PGDG.rhel9.8`, `data_checksums on`, `io_method worker`.
  Disk space was tight (the R table needs ~4.5 GB per cluster incl. the rewrite and WAL), so `repack_test.sh` drops `bloat_t`
  after every run.

## 3. Environment card

- 🤖 `.\lab.ps1 preflight` → `results\preflight_<ts>.txt` (read-only).
- ✋ `Get-Content -Raw guest\preflight.sh | ssh root@192.168.56.40 "tr -d '\r' | bash -s" > results\preflight_manual.txt`
- **Our run:** VirtualBox 7.2.22, Rocky 9.8, 4 CPUs, 3,655 MB RAM, `/pgdata` on `nvme0n1` (mq-deadline, `nr_requests 256`).
  Defaults that differ between the two versions:

  | Setting | PG18 | PG19 | Effect on the tests |
  |---|---|---|---|
  | `jit` | on | **off** | test F sets `jit = off` in both |
  | `io_workers` / `io_min_workers`–`io_max_workers` | 3 (fixed) | **2–8 (autoscaling)** | part of "the new version", not aligned |
  | `log_lock_waits` | off | **on** | log only; test R produces lock-wait entries in PG19 |
  | `max_locks_per_transaction` | 64 | **128** | none |
  | `default_toast_compression` | pglz | **lz4** | none (64-char column, no TOAST) |
  | `max_repack_replication_slots` | — | **5** | new; REPACK CONCURRENTLY uses a slot |
  | `effective_wal_level` | — | **replica** | new; with `wal_level = replica` |

## 4. Copy the scripts

- 🤖 `.\lab.ps1 push` (copies `bench\` and `sql\`, strips CR, `bash -n` syntax check).
- ✋

  ```powershell
  ssh root@192.168.56.40 "mkdir -p /root/pg19lab/results && chmod 755 /root /root/pg19lab"
  scp -r bench sql root@192.168.56.40:/root/pg19lab/
  ssh root@192.168.56.40 "sed -i 's/\r$//' /root/pg19lab/bench/* /root/pg19lab/sql/*; chmod -R a+rX,go-w /root/pg19lab; bash -n /root/pg19lab/bench/*.sh && echo OK"
  ```

## 5. Trial

- 🤖 `.\lab.ps1 trial -DryRun` (plan), `.\lab.ps1 trial`, then `.\lab.ps1 progress` until the line `KONIEC` (end), then `.\lab.ps1 fetch`.
- ✋ The run is started with `systemd-run`, so it does not depend on the SSH session:

  ```powershell
  ssh root@192.168.56.40 "systemd-run --unit=pg19lab-run --collect --setenv=SUITE=all --setenv=TRIAL=1 /bin/bash -c 'bash /root/pg19lab/bench/run_all.sh >> /root/pg19lab/run.log 2>&1'"
  ssh root@192.168.56.40 "tail -n 25 /root/pg19lab/run.log"                 # progress
  scp -r root@192.168.56.40:/root/pg19lab/results/* results\                # fetch
  scp root@192.168.56.40:/root/pg19lab/run.log results\run.log
  ```

- **Why:** all three tests on small tables (400 k rows in R, 200 k in F) catch script errors before an hour of measurement,
  and show whether `REPACK (CONCURRENTLY)` works with `wal_level = replica` — it does.
- **Two bugs found here:** (1) `systemd-run -p StandardOutput=append:/root/...` failed with `status=209/STDOUT` — systemd opens
  the file itself and SELinux denies it; the log is now opened by `bash -c '… >> run.log'`. Diagnose with
  `journalctl -u pg19lab-run --no-pager -n 30`. (2) "tps during the operation" was computed from seconds whose middle falls
  into the window — nonsense for sub-second operations; now every second overlapping the window counts.

## 6. Part 1: R, F, U

- 🤖 `.\lab.ps1 run` (R 3 runs × PG18 VF, PG19 VF, PG19 REPACK CONC. on 20 M rows; F 5 runs × PG18, PG19 on 5 M rows, order alternating; U once),
  `.\lab.ps1 progress`, `.\lab.ps1 fetch`. One test only: `.\lab.ps1 run -Suite repack -RunsR 3` (also `fk`, `upgrade`).
- ✋ As in step 5 with `--setenv=SUITE=all --setenv=RUNS_R=3 --setenv=RUNS_F=5` instead of `TRIAL=1`.
- **Our run** (`20261123_183133_full`): `KONIEC suite=all fail=0`, 27 min, R 9/9 and F 20/20 runs `ok=1`.

## 7. Part 2: REPACK at 1/4/8 sessions

- **Why:** in part 1 REPACK stalled writes for 5–6 s at the end. Hypothesis: under the lock it applies the changes captured
  meanwhile, so more writes = a longer lock. The same REPACK with 1, 4 and 8 writing sessions, 3 runs, order 1-4-8 / 8-4-1 / 1-4-8;
  "4 sessions" repeats part 1 as a reproducibility check.
- 🤖 `.\lab.ps1 run -Suite clients -RunsR 3`
- ✋ `--setenv=SUITE=clients --setenv=RUNS_R=3` (optionally `--setenv=CLIENTS_LIST=1,4,8`).
- **Our run** (`20261123_192156_full`, 26 min, 9/9 `ok=1`): duration 13.6 / 32.5 / 93.1 s, writes stalled **0 / 5 / 18 s**,
  longest wait 0.1 / 6.1 / 19.6 s. The hypothesis holds.

## 8. Control: VACUUM FULL at 1 and 8 sessions

- **Why:** part 1 had VACUUM FULL at 4 sessions only; "REPACK at 8 sessions is worse than VACUUM FULL" needs the same load on both sides.
- 🤖 `.\lab.ps1 run -Suite clients -RunsR 3 -ExtraEnv 'VARIANT_C=vacuum_full CLIENTS_LIST=1,8'`
- ✋ `--setenv=SUITE=clients --setenv=RUNS_R=3 --setenv=VARIANT_C=vacuum_full --setenv=CLIENTS_LIST=1,8`
- **Our run** (`20261123_194837_full`, 16 min, `fail=0`): writes stalled 11 s at 1 session, **15 s** at 8 (15–21).
- **Lesson:** after the first run (21 s) REPACK at 8 sessions seemed to win; the median of 3 runs says the opposite (VF 15 s, REPACK 18 s).
- Copy new scripts to the VM only after the previous run has ended: bash reads a running script while it executes.

## 9. Report and page

```powershell
python report\summarize.py --ts 20261123_183133_full --out results\SUMMARY_20261123_183133_full.md   # medians
python report\timeline_stats.py 20261123_183133_full                                                # where writes stall in time
ssh root@192.168.56.40 'grep -h "acquired.*after" /pgdata/19/data/log/*.log'                       # lock waits logged by PG19
python report\build_explainer.py --part1 20261123_183133_full --part2 20261123_192156_full --control 20261123_194837_full `
  --template report\explainer_template_en.html --out ..\docs\pg19\index.html                        # EN page
python report\build_explainer.py --part1 20261123_183133_full --part2 20261123_192156_full --control 20261123_194837_full `
  --out ..\docs\pg19\index_pl.html                                                                  # PL page
```

## 🏁 State after the run / Rollback

- PG18 active (as at boot); PG19 installed, stopped, not enabled. Database `labtest` in both clusters. `/pgdata`: 17 GB free.
- Stop the VM: `.\lab.ps1 stop`. Full rollback of PG19 and the test data: [README, section Rollback](../README.md).
