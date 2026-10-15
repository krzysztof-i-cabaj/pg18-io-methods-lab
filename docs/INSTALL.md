# 🛠️ Installation — building the test lab from scratch

[![Host](https://img.shields.io/badge/Host-Windows_11_+_VirtualBox_7-blue)]()
[![Guest](https://img.shields.io/badge/Guest-Rocky_Linux_9.8-orange)]()
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-18_(PGDG)-336791)]()
[![Credentials](https://img.shields.io/badge/Credentials-SSH_key_only-success)]()
[![Paths](https://img.shields.io/badge/Paths-scripted_%7C_manual-blueviolet)]()

> 🎯 A clean, reproducible path from an empty Windows host to a measured PostgreSQL 18 `io_method` benchmark.
> Every stage can be done in two ways — pick one per stage, they produce the same result. 🇵🇱 [Wersja polska](INSTALL_PL.md)

| | Path | For whom |
|---|---|---|
| 🤖 | **Scripted path (automatic / semi-automatic)** — `lab.ps1 <verb>`, one command per stage, run in order | you want the result, not the keystrokes |
| ✋ | **Manual path** — plain `VBoxManage`, installer, `dnf`, `psql`; no scripts from this repository | you want to see and control every step, or you are not on Windows |

The manual path is written so it works on any host with VirtualBox (Windows, Linux, macOS): only the host-side
commands differ in syntax. All `✋` commands on the VM are run as `root`.

---

## 📋 1. Requirements

| Item | Value |
|---|---|
| Host OS | Windows 11 + PowerShell 7 (scripted path); any VirtualBox host (manual path) |
| Hypervisor | VirtualBox 7.x |
| Python | 3.8+ on the host (serves the kickstart file, generates the report) |
| SSH | OpenSSH client + key pair `~/.ssh/id_ed25519` (`ssh-keygen -t ed25519`) |
| ISO | `Rocky-9.8-x86_64-minimal.iso` (SHA-256 `d338032cd1cdd41c67139f2f71b4c832c8e4a21943106519db9c7137df7a63d4`) |
| Disk | ~80 GB free in the VirtualBox machine folder (VM + 40 GB fixed data disk) |
| Network | VirtualBox host-only adapter `192.168.56.1/24`; internet for the VM via NAT |

## ⚙️ 2. Host configuration

### 🤖 Scripted path

Edit `lab.config.psd1` if your values differ:

| Key | Default | Meaning |
|---|---|---|
| `Vm.Ip` | `192.168.56.40` | static address on the host-only network |
| `Vm.Ram` / `Vm.Cpu` | `4096` / `4` | small RAM on purpose — the test table is 3–4× RAM |
| `Vm.OsDiskMb` | `20480` | OS disk (dynamic) |
| `Vm.DataDiskMb` | `40960` | data disk for `PGDATA` (**fixed size**) |
| `Iso.Path` / `Iso.Sha256` | — | local ISO and its checksum |
| `KsServer.Port` | `8000` | HTTP port of the kickstart server on the host |

Allow the kickstart port from the lab network (PowerShell **as administrator**, once), then run the pre-flight check:

```powershell
New-NetFirewallRule -DisplayName 'pgio-lab-ks-8000' -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort 8000 -RemoteAddress 192.168.56.0/24
.\lab.ps1 plan              # no changes: checks everything and prints the commands build will run
```

`plan` checks VirtualBox, the ISO checksum, the SSH key, the host-only adapter, that `.40` is free, that port 8000 is free,
the firewall rule, free disk space and that **no other VM is running**; it renders `kickstart/pgio.ks`.

### ✋ Manual path

```powershell
Get-FileHash D:\ISOs\Rocky-9.8-x86_64-minimal.iso -Algorithm SHA256   # Linux/macOS: sha256sum <iso>
VBoxManage list hostonlyifs          # an adapter with IPAddress 192.168.56.1 must exist
VBoxManage list runningvms           # should be empty: other VMs disturb the measurements
Test-Connection 192.168.56.40 -Count 1 -Quiet   # False = address is free
```

If the adapter is missing: `VBoxManage hostonlyif create`, then
`VBoxManage hostonlyif ipconfig "<name it printed>" --ip 192.168.56.1 --netmask 255.255.255.0`;
and open TCP 8000 for `192.168.56.0/24` in your host firewall (only needed if you use the kickstart in step 3).

## 🏗️ 3. Build the VM

### 🤖 Scripted path

```powershell
.\lab.ps1 build             # ~10–20 min, unattended
```

What happens:

1. A small Python HTTP server on `192.168.56.1:8000` serves the `kickstart/` directory only.
2. `VBoxManage` creates VM `pgio` exactly as in the manual path below (host I/O cache off, fixed data disk, SSD flag).
3. The VM boots the ISO; at the boot menu the script types the boot parameters (`VBoxManage controlvm … keyboardputscancode`).
4. Kickstart installs Rocky Linux 9.8: the **OS disk is the smallest disk** (chosen in `%pre`, because `sdX` names are not
   stable between boots), the data disk is left untouched, root password **locked**, your public key in
   `/root/.ssh/authorized_keys`, and `kernel.io_uring_disabled = 0` (RHEL/Rocky 9 ship `2` = io_uring disabled).
5. The host waits for SSH, detaches the ISO and stops the kickstart server.

### ✋ Manual path

**3a. Create the VM** (Windows: `VBoxManage` is in `C:\Program Files\Oracle\VirtualBox\`; use `` ` `` instead of `\` for line breaks):

```bash
VM=pgio; DIR="$HOME/VirtualBox VMs/$VM"; ISO=/path/to/Rocky-9.8-x86_64-minimal.iso
HOSTONLY="VirtualBox Host-Only Ethernet Adapter"   # the Name from: VBoxManage list hostonlyifs (Linux/macOS: vboxnet0)
VBoxManage createvm --name $VM --ostype RedHat_64 --register
VBoxManage modifyvm $VM --memory 4096 --cpus 4 \
    --nic1 hostonly --hostonlyadapter1 "$HOSTONLY" --nic2 nat \
    --boot1 disk --boot2 dvd --boot3 none --boot4 none --ioapic on --rtcuseutc on \
    --graphicscontroller vmsvga --vram 16 --audio-driver none
VBoxManage createmedium disk --filename "$DIR/$VM.vdi"      --size 20480 --format VDI
VBoxManage createmedium disk --filename "$DIR/$VM-data.vdi" --size 40960 --format VDI --variant Fixed
VBoxManage storagectl $VM --name SATA --add sata --controller IntelAhci --portcount 3 --hostiocache off
VBoxManage storageattach $VM --storagectl SATA --port 0 --type hdd --medium "$DIR/$VM.vdi" --nonrotational on
VBoxManage storageattach $VM --storagectl SATA --port 1 --type dvddrive --medium "$ISO"
VBoxManage storageattach $VM --storagectl SATA --port 2 --type hdd --medium "$DIR/$VM-data.vdi" --nonrotational on
VBoxManage startvm $VM
```

Why these flags matter for the benchmark:

| Flag | Reason |
|---|---|
| `--hostiocache off` | with the host cache on, Windows/Linux caches the VM's disk reads and a "cold cache" in the guest is no longer cold |
| `--variant Fixed` | a preallocated data disk does not grow during the test, so no VDI growth overhead in the measurements |
| `--nonrotational on` | the host disk is NVMe; the guest should see an SSD (`rotational=0`) |
| `--boot1 disk --boot2 dvd` | the empty disk falls through to the DVD on first boot; after installation the VM boots from disk |
| `--memory 4096` | the 13 GB test table is ~3.6× RAM, so a full scan cannot be served from memory |

**3b. Install Rocky Linux** — choose one:

- **With the kickstart file (same result as the scripted path).** Copy `kickstart/pgio.ks.tmpl` to `kickstart/pgio.ks` and replace
  `{{IP}}` → `192.168.56.40`, `{{HOSTNAME}}` → `pgio.lab.test`, `{{SSH_PUBKEY}}` → the content of `~/.ssh/id_ed25519.pub`.
  Serve it from the repository root: `python -m http.server 8000 --bind 192.168.56.1`.
  At the ISO boot menu select *Install Rocky Linux 9.8*, press **Tab** and append to the boot line:

  ```text
  inst.ks=http://192.168.56.1:8000/kickstart/pgio.ks inst.text ip=192.168.56.40:::255.255.255.0:pgio.lab.test:enp0s3:none
  ```

- **Interactive installer (no kickstart).** *Installation Destination*: only the **20 GB** disk, automatic LVM, no swap
  needed; leave the 40 GB disk unselected. *Network*: `enp0s3` static `192.168.56.40/24`, no gateway,
  DNS `1.1.1.1`; `enp0s8` DHCP (NAT). Hostname `pgio.lab.test`. *Software*: Minimal Install. *Root*: set a password or lock root
  and create an admin user. After the first boot add your key and enable io_uring:

  ```bash
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  echo '<content of id_ed25519.pub>' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
  restorecon -R /root/.ssh
  echo 'kernel.io_uring_disabled = 0' > /etc/sysctl.d/90-pgio-io_uring.conf && sysctl --system
  ```

**3c. After installation:** `VBoxManage storageattach pgio --storagectl SATA --port 1 --type dvddrive --medium none`,
then `ssh root@192.168.56.40 hostname` must answer `pgio.lab.test`.

## 🐘 4. Install PostgreSQL 18

### 🤖 Scripted path

```powershell
.\lab.ps1 provision -DryRun   # prints every command, changes nothing
.\lab.ps1 provision           # idempotent, safe to repeat
```

`guest/provision.sh` finds the data disk itself (the only **empty** disk ≥ 35 GB) and refuses to touch a disk with partitions
or signatures; then it performs exactly the manual steps below.

### ✋ Manual path

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT      # find the EMPTY 40 GB disk — e.g. /dev/sda; names can change between boots
DEV=/dev/sda                                   # <- set it to what lsblk shows
wipefs -n $DEV                                 # must print nothing (no signatures) before you format it
mkfs.xfs -L pgdata $DEV
mkdir -p /pgdata && echo 'LABEL=pgdata /pgdata xfs defaults,noatime 0 0' >> /etc/fstab
systemctl daemon-reload && mount /pgdata

dnf -y install https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
dnf -y module disable postgresql
dnf -y install postgresql18-server postgresql18-contrib liburing sysstat policycoreutils-python-utils

mkdir -p /pgdata/18/data && chown -R postgres:postgres /pgdata/18 && chmod 700 /pgdata/18/data
semanage fcontext -a -t postgresql_db_t '/pgdata(/.*)?' && restorecon -R /pgdata
mkdir -p /etc/systemd/system/postgresql-18.service.d
printf '[Service]\nEnvironment=PGDATA=/pgdata/18/data\n' > /etc/systemd/system/postgresql-18.service.d/pgdata.conf
systemctl daemon-reload
PGSETUP_INITDB_OPTIONS='--data-checksums' /usr/pgsql-18/bin/postgresql-18-setup initdb

mkdir -p /pgdata/18/data/conf.d
echo "include_dir = 'conf.d'" >> /pgdata/18/data/postgresql.conf
cat > /pgdata/18/data/conf.d/10-lab.conf <<'EOF'
listen_addresses = 'localhost'
shared_buffers = '1GB'
track_io_timing = on
EOF
chown -R postgres:postgres /pgdata/18/data/conf.d
systemctl enable --now postgresql-18
sudo -u postgres psql -Xc "select version()" -c "show data_directory" -c "show io_method"
```

## 🪪 5. Environment card

### 🤖 Scripted path

```powershell
.\lab.ps1 envcard             # -> results\env_card.txt
```

### ✋ Manual path

Record the facts a reader needs to judge the numbers:

```bash
VBoxManage --version; VBoxManage showvminfo pgio --machinereadable | grep -i hostiocache     # on the host
cat /etc/rocky-release; uname -r; lscpu | grep -E 'Model name|^CPU\(s\)'; free -m
lsblk -o NAME,SIZE,ROTA,TYPE,FSTYPE,MOUNTPOINT; cat /sys/block/sda/queue/{scheduler,rotational,read_ahead_kb}
sysctl kernel.io_uring_disabled                      # must be 0
/usr/pgsql-18/bin/pg_config --configure | grep -o with-liburing    # io_uring support compiled in
sudo -u postgres psql -Xc "select name, setting, unit from pg_settings where name like 'io\_%' or name in
  ('effective_io_concurrency','maintenance_io_concurrency','shared_buffers','track_io_timing') order by 1"
```

## 📦 6. Test data

### 🤖 Scripted path

```powershell
.\lab.ps1 loaddata            # copies sql/ and bench/ to /root/pgio, runs in the background (~15 min); log: /root/pgio/load.log
```

### ✋ Manual path

```bash
scp -r sql bench root@192.168.56.40:/root/pgio/                 # on the host
cd /tmp && sudo -u postgres psql -X -f /root/pgio/sql/01_create_test_data.sql | tee /root/pgio/load.log
```

`sql/01_create_test_data.sql` creates table `fakty`: **100 M rows (~13 GB)**, deterministic (`setseed(0.42)`), columns `d` (date)
and `r` (bigint) random and uncorrelated with the physical order; primary key, indexes on `d` and `r`, `VACUUM ANALYZE`.
Expected at the end: table ~13 GB, indexes ~4.9 GB, `correlation` of `d` and `r` close to 0.

## ✅ 7. Plan check (EXPLAIN only)

### 🤖 Scripted path

```powershell
.\lab.ps1 plans               # every test: plan + PASS/FAIL
```

### ✋ Manual path

Each line of `bench/tests.conf` is `id | expected plan node | session settings | query`. Run the settings and `EXPLAIN` of the query:

```sql
SET max_parallel_workers_per_gather = 0;
EXPLAIN SELECT count(*), avg(v) FROM fakty;                                  -- T1a: expect Seq Scan
RESET max_parallel_workers_per_gather;
EXPLAIN SELECT count(*), avg(v) FROM fakty;                                  -- T1b: expect Parallel Seq Scan
SET max_parallel_workers_per_gather = 0;
EXPLAIN SELECT count(*), avg(v) FROM fakty WHERE d = '2022-03-01';            -- T2: expect Bitmap Heap Scan
EXPLAIN SELECT sum(v) FROM (SELECT v FROM fakty WHERE r >= 500000000000
                            ORDER BY r LIMIT 5000) s;                        -- T3: expect Index Scan
```

If a plan does not contain the expected node, the test does not measure what its name says — fix the query before measuring.

## ⏱️ 8. Measurements

### 🤖 Scripted path

```powershell
.\lab.ps1 bench 7             # 7 interleaved series in the background on the VM (~85 min); log: /root/pgio/bench_run.log
.\lab.ps1 fetch               # copy /root/pgio/results/* to results\
```

`bench/run_bench.sh` writes one CSV row per measurement and rejects (`plan_ok=0`) any run whose plan lacks the expected node.
Procedure details: [METHODOLOGY.md](METHODOLOGY.md).

### ✋ Manual path

One measurement = switch the mode, make the cache cold, run `EXPLAIN ANALYZE`. Repeat for every test, mode and series:

```bash
MODE=io_uring                                     # sync | worker | io_uring
sudo -u postgres psql -Xc "ALTER SYSTEM SET io_method = '$MODE'"
systemctl stop postgresql-18; sync; echo 3 > /proc/sys/vm/drop_caches; systemctl start postgresql-18   # cold cache
sudo -u postgres psql -Xc "show io_method"        # must print $MODE
sudo -u postgres psql -X <<'SQL'
SET max_parallel_workers_per_gather = 0;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) SELECT count(*), avg(v) FROM fakty;     -- T1a
SQL
```

Read `Execution Time`, `Buffers: shared read` and `I/O Timings: shared read` and check the plan node.
For a **warm** measurement (T2, T3 only) run the query once, then `EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)` without a restart.
For **VACUUM (T4)** recreate the table before every run, make the cache cold, then time it:

```sql
DROP TABLE IF EXISTS fakty_vac;
CREATE TABLE fakty_vac WITH (autovacuum_enabled = off) AS SELECT * FROM fakty WHERE id <= 10000000;
CREATE INDEX fakty_vac_d_idx ON fakty_vac (d);
DELETE FROM fakty_vac WHERE id % 10 = 0;
CHECKPOINT;
-- cold-cache restart here (stop, drop_caches, start), then:
\timing on
VACUUM (VERBOSE) fakty_vac;          -- expect 1,000,000 removed tuples in every mode
```

Interleave the modes (`sync → worker → io_uring`, then again) instead of running all series of one mode in a row,
and finish with `ALTER SYSTEM RESET io_method` and a restart.

### 🔁 Optional: control run with the data disk on an NVMe controller

Move only the data disk to an emulated NVMe controller (host, VM powered off — `ssh root@192.168.56.40 systemctl poweroff`):

```bash
VBoxManage storageattach pgio --storagectl SATA --port 2 --medium none
VBoxManage storagectl pgio --name NVMe --add pcie --controller NVMe --portcount 1 --hostiocache off
VBoxManage storageattach pgio --storagectl NVMe --port 0 --device 0 --type hdd --medium "$DIR/pgio-data.vdi" --nonrotational on
VBoxManage startvm pgio --type headless
```

After boot `findmnt /pgdata` shows `/dev/nvme0n1` (mounted by label, nothing else to change). Then:

| Path | Command (on the VM) |
|---|---|
| 🤖 | `grep -E '^(T1b\|T2)\|' /root/pgio/bench/tests.conf > /root/pgio/tests_control.conf` then<br>`CONF=/root/pgio/tests_control.conf RUNS=3 WARM_TESTS=none OUT_DIR=/root/pgio/control bash /root/pgio/bench/run_bench.sh` |
| ✋ | the single-measurement procedure above, for T1b, T2 and T4 only, 3 series |

Keep the control results apart from the main run (`OUT_DIR`); the report reads them from `results/control_nvme/`.
To go back: the same three `storageattach`/`storagectl` steps in reverse (`--storagectl NVMe --port 0 --medium none`,
`storagectl pgio --name NVMe --remove`, attach the disk to `SATA` port 2).

## 📊 9. Report

### 🤖 Scripted path

```powershell
python report\make_report.py --dry-run     # medians on screen, nothing written
python report\make_report.py               # docs\RESULTS*.md, docs\charts\*.svg, docs\index*.html
```

Optional hand-written conclusions are taken from `report/findings_en.md` and `report/findings_pl.md`.

### ✋ Manual path

Load the CSV into PostgreSQL and compute the same statistics:

```sql
CREATE TABLE bench_raw (ts timestamp, series int, io_method text, test text, cache text, plan_ok int,
                        exec_ms numeric, shared_hit bigint, shared_read bigint, io_read_ms numeric, note text);
\copy bench_raw FROM 'raw_<timestamp>.csv' CSV HEADER
SELECT test, cache, io_method, count(*) AS n,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY exec_ms) AS median_ms,
       min(exec_ms), max(exec_ms)
FROM bench_raw WHERE plan_ok = 1
GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;
```

## ↩️ Rollback

| Path | Command |
|---|---|
| 🤖 | `.\lab.ps1 destroy pgio` — power off, unregister and delete the VM with its disks |
| ✋ | `VBoxManage controlvm pgio poweroff` then `VBoxManage unregistervm pgio --delete` |

Remove the firewall rule when you no longer need it: `Remove-NetFirewallRule -DisplayName 'pgio-lab-ks-8000'` (as administrator).
