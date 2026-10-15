# 🛠️ Instalacja — budowa labu testowego od zera

[![Host](https://img.shields.io/badge/Host-Windows_11_+_VirtualBox_7-blue)]()
[![Gość](https://img.shields.io/badge/Gość-Rocky_Linux_9.8-orange)]()
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-18_(PGDG)-336791)]()
[![Dostęp](https://img.shields.io/badge/Dostęp-tylko_klucz_SSH-success)]()
[![Ścieżki](https://img.shields.io/badge/Ścieżki-skryptowa_%7C_ręczna-blueviolet)]()

> 🎯 Czysta, powtarzalna droga od pustego hosta Windows do zmierzonego benchmarku `io_method` w PostgreSQL 18.
> Każdy etap można wykonać na dwa sposoby — wybierz jeden dla każdego etapu, wynik jest ten sam. 🇬🇧 [English version](INSTALL.md)

| | Ścieżka | Dla kogo |
|---|---|---|
| 🤖 | **Ścieżka skryptowa (automatycznie / półautomatycznie)** — `lab.ps1 <verb>`, jedno polecenie na etap, uruchamiane po kolei | chcesz wyniku, nie klikania |
| ✋ | **Ścieżka ręczna** — zwykłe `VBoxManage`, instalator, `dnf`, `psql`; bez skryptów z tego repozytorium | chcesz widzieć i kontrolować każdy krok albo nie pracujesz na Windows |

Ścieżka ręczna działa na każdym hoście z VirtualBox (Windows, Linux, macOS) — różni się tylko składnia poleceń po stronie hosta.
Wszystkie polecenia `✋` na VM wykonujesz jako `root`.

---

## 📋 1. Wymagania

| Element | Wartość |
|---|---|
| System hosta | Windows 11 + PowerShell 7 (ścieżka skryptowa); dowolny host z VirtualBox (ścieżka ręczna) |
| Hipernadzorca | VirtualBox 7.x |
| Python | 3.8+ na hoście (serwuje plik kickstart, generuje raport) |
| SSH | klient OpenSSH + para kluczy `~/.ssh/id_ed25519` (`ssh-keygen -t ed25519`) |
| ISO | `Rocky-9.8-x86_64-minimal.iso` (SHA-256 `d338032cd1cdd41c67139f2f71b4c832c8e4a21943106519db9c7137df7a63d4`) |
| Dysk | ~80 GB wolnego miejsca w katalogu maszyn VirtualBox (VM + dysk danych 40 GB o stałym rozmiarze) |
| Sieć | adapter host-only VirtualBox `192.168.56.1/24`; internet dla VM przez NAT |

## ⚙️ 2. Konfiguracja hosta

### 🤖 Ścieżka skryptowa

Zmień `lab.config.psd1`, jeśli Twoje wartości są inne:

| Klucz | Domyślnie | Znaczenie |
|---|---|---|
| `Vm.Ip` | `192.168.56.40` | stały adres w sieci host-only |
| `Vm.Ram` / `Vm.Cpu` | `4096` / `4` | celowo mało RAM — tabela testowa to 3–4× RAM |
| `Vm.OsDiskMb` | `20480` | dysk systemowy (dynamiczny) |
| `Vm.DataDiskMb` | `40960` | dysk danych na `PGDATA` (**stały rozmiar**) |
| `Iso.Path` / `Iso.Sha256` | — | lokalny obraz ISO i jego suma kontrolna |
| `KsServer.Port` | `8000` | port HTTP serwera kickstart na hoście |

Otwórz port kickstartu dla sieci labu (PowerShell **jako administrator**, jednorazowo), potem kontrola wstępna:

```powershell
New-NetFirewallRule -DisplayName 'pgio-lab-ks-8000' -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort 8000 -RemoteAddress 192.168.56.0/24
.\lab.ps1 plan              # bez zmian: sprawdza wszystko i wypisuje polecenia, które wykona build
```

`plan` sprawdza VirtualBox, sumę ISO, klucz SSH, adapter host-only, czy adres `.40` jest wolny, czy port 8000 jest wolny,
regułę zapory, miejsce na dysku i to, że **nie działa żadna inna VM**; renderuje `kickstart/pgio.ks`.

### ✋ Ścieżka ręczna

```powershell
Get-FileHash D:\ISOs\Rocky-9.8-x86_64-minimal.iso -Algorithm SHA256   # Linux/macOS: sha256sum <iso>
VBoxManage list hostonlyifs          # musi istnieć adapter z IPAddress 192.168.56.1
VBoxManage list runningvms           # powinno być pusto: inne VM zaburzają pomiary
Test-Connection 192.168.56.40 -Count 1 -Quiet   # False = adres wolny
```

Jeśli adaptera brakuje: `VBoxManage hostonlyif create`, potem
`VBoxManage hostonlyif ipconfig "<nazwa, którą wypisało>" --ip 192.168.56.1 --netmask 255.255.255.0`;
w zaporze hosta otwórz TCP 8000 dla `192.168.56.0/24` (potrzebne tylko przy instalacji z kickstartem w kroku 3).

## 🏗️ 3. Budowa VM

### 🤖 Ścieżka skryptowa

```powershell
.\lab.ps1 build             # ~10–20 min, bez obsługi
```

Co się dzieje:

1. Mały serwer HTTP w Pythonie na `192.168.56.1:8000` udostępnia tylko katalog `kickstart/`.
2. `VBoxManage` tworzy VM `pgio` dokładnie tak jak w ścieżce ręcznej poniżej (cache I/O hosta wyłączony, stały dysk danych, flaga SSD).
3. VM startuje z ISO; w menu startowym skrypt wpisuje parametry startu (`VBoxManage controlvm … keyboardputscancode`).
4. Kickstart instaluje Rocky Linux 9.8: **dysk systemowy to najmniejszy dysk** (wybierany w `%pre`, bo nazwy `sdX` nie są stałe
   między uruchomieniami), dysk danych zostaje nietknięty, hasło roota **zablokowane**, Twój klucz publiczny w
   `/root/.ssh/authorized_keys`, `kernel.io_uring_disabled = 0` (RHEL/Rocky 9 mają domyślnie `2` = io_uring wyłączony).
5. Host czeka na SSH, odłącza ISO i zatrzymuje serwer kickstart.

### ✋ Ścieżka ręczna

**3a. Utwórz VM** (Windows: `VBoxManage` jest w `C:\Program Files\Oracle\VirtualBox\`; łamanie linii `` ` `` zamiast `\`):

```bash
VM=pgio; DIR="$HOME/VirtualBox VMs/$VM"; ISO=/sciezka/do/Rocky-9.8-x86_64-minimal.iso
HOSTONLY="VirtualBox Host-Only Ethernet Adapter"   # Name z: VBoxManage list hostonlyifs (Linux/macOS: vboxnet0)
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

Dlaczego te flagi są ważne dla pomiaru:

| Flaga | Powód |
|---|---|
| `--hostiocache off` | z cache hosta Windows/Linux buforuje odczyty dysku VM i „zimny cache” w gościu przestaje być zimny |
| `--variant Fixed` | prealokowany dysk danych nie rośnie w trakcie testu — brak narzutu rozrastania VDI w wynikach |
| `--nonrotational on` | dysk hosta to NVMe; gość ma widzieć SSD (`rotational=0`) |
| `--boot1 disk --boot2 dvd` | pusty dysk przy pierwszym starcie przepuszcza na DVD; po instalacji VM startuje z dysku |
| `--memory 4096` | tabela testowa 13 GB to ~3,6× RAM, więc pełnego skanu nie da się obsłużyć z pamięci |

**3b. Zainstaluj Rocky Linux** — wybierz jedno:

- **Z plikiem kickstart (ten sam wynik co ścieżka skryptowa).** Skopiuj `kickstart/pgio.ks.tmpl` do `kickstart/pgio.ks` i zamień
  `{{IP}}` → `192.168.56.40`, `{{HOSTNAME}}` → `pgio.lab.test`, `{{SSH_PUBKEY}}` → zawartość `~/.ssh/id_ed25519.pub`.
  Udostępnij go z katalogu głównego repozytorium: `python -m http.server 8000 --bind 192.168.56.1`.
  W menu startowym ISO wybierz *Install Rocky Linux 9.8*, naciśnij **Tab** i dopisz do linii startowej:

  ```text
  inst.ks=http://192.168.56.1:8000/kickstart/pgio.ks inst.text ip=192.168.56.40:::255.255.255.0:pgio.lab.test:enp0s3:none
  ```

- **Instalator interaktywny (bez kickstartu).** *Installation Destination*: tylko dysk **20 GB**, automatyczny LVM, swap niepotrzebny;
  dysku 40 GB nie zaznaczaj. *Network*: `enp0s3` statycznie `192.168.56.40/24`, bez bramy, DNS `1.1.1.1`; `enp0s8` DHCP (NAT).
  Hostname `pgio.lab.test`. *Software*: Minimal Install. *Root*: ustaw hasło albo zablokuj roota i utwórz użytkownika
  administracyjnego. Po pierwszym starcie dodaj klucz i odblokuj io_uring:

  ```bash
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  echo '<zawartość id_ed25519.pub>' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
  restorecon -R /root/.ssh
  echo 'kernel.io_uring_disabled = 0' > /etc/sysctl.d/90-pgio-io_uring.conf && sysctl --system
  ```

**3c. Po instalacji:** `VBoxManage storageattach pgio --storagectl SATA --port 1 --type dvddrive --medium none`,
potem `ssh root@192.168.56.40 hostname` musi odpowiedzieć `pgio.lab.test`.

## 🐘 4. Instalacja PostgreSQL 18

### 🤖 Ścieżka skryptowa

```powershell
.\lab.ps1 provision -DryRun   # wypisuje każde polecenie, niczego nie zmienia
.\lab.ps1 provision           # idempotentne, można powtarzać
```

`guest/provision.sh` sam znajduje dysk danych (jedyny **pusty** dysk ≥ 35 GB) i odmawia pracy na dysku z partycjami
lub sygnaturami; potem wykonuje dokładnie kroki ze ścieżki ręcznej poniżej.

### ✋ Ścieżka ręczna

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT      # znajdź PUSTY dysk 40 GB — np. /dev/sda; nazwy mogą się zmieniać między startami
DEV=/dev/sda                                   # <- ustaw to, co pokazuje lsblk
wipefs -n $DEV                                 # nie może nic wypisać (brak sygnatur), zanim go sformatujesz
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

## 🪪 5. Karta środowiska

### 🤖 Ścieżka skryptowa

```powershell
.\lab.ps1 envcard             # -> results\env_card.txt
```

### ✋ Ścieżka ręczna

Zapisz fakty, których czytelnik potrzebuje, by ocenić liczby:

```bash
VBoxManage --version; VBoxManage showvminfo pgio --machinereadable | grep -i hostiocache     # na hoście
cat /etc/rocky-release; uname -r; lscpu | grep -E 'Model name|^CPU\(s\)'; free -m
lsblk -o NAME,SIZE,ROTA,TYPE,FSTYPE,MOUNTPOINT; cat /sys/block/sda/queue/{scheduler,rotational,read_ahead_kb}
sysctl kernel.io_uring_disabled                      # musi być 0
/usr/pgsql-18/bin/pg_config --configure | grep -o with-liburing    # obsługa io_uring wkompilowana
sudo -u postgres psql -Xc "select name, setting, unit from pg_settings where name like 'io\_%' or name in
  ('effective_io_concurrency','maintenance_io_concurrency','shared_buffers','track_io_timing') order by 1"
```

## 📦 6. Dane testowe

### 🤖 Ścieżka skryptowa

```powershell
.\lab.ps1 loaddata            # kopiuje sql/ i bench/ do /root/pgio, działa w tle (~15 min); log: /root/pgio/load.log
```

### ✋ Ścieżka ręczna

```bash
scp -r sql bench root@192.168.56.40:/root/pgio/                 # na hoście
cd /tmp && sudo -u postgres psql -X -f /root/pgio/sql/01_create_test_data.sql | tee /root/pgio/load.log
```

`sql/01_create_test_data.sql` tworzy tabelę `fakty`: **100 mln wierszy (~13 GB)**, deterministycznie (`setseed(0.42)`), kolumny `d` (data)
i `r` (bigint) losowe i nieskorelowane z fizyczną kolejnością; klucz główny, indeksy na `d` i `r`, `VACUUM ANALYZE`.
Oczekiwane na końcu: tabela ~13 GB, indeksy ~4,9 GB, `correlation` dla `d` i `r` bliskie 0.

## ✅ 7. Kontrola planów (tylko EXPLAIN)

### 🤖 Ścieżka skryptowa

```powershell
.\lab.ps1 plans               # każdy test: plan + PASS/FAIL
```

### ✋ Ścieżka ręczna

Każda linia `bench/tests.conf` to `id | oczekiwany węzeł planu | ustawienia sesji | zapytanie`. Wykonaj ustawienia i `EXPLAIN` zapytania:

```sql
SET max_parallel_workers_per_gather = 0;
EXPLAIN SELECT count(*), avg(v) FROM fakty;                                  -- T1a: oczekiwany Seq Scan
RESET max_parallel_workers_per_gather;
EXPLAIN SELECT count(*), avg(v) FROM fakty;                                  -- T1b: oczekiwany Parallel Seq Scan
SET max_parallel_workers_per_gather = 0;
EXPLAIN SELECT count(*), avg(v) FROM fakty WHERE d = '2022-03-01';            -- T2: oczekiwany Bitmap Heap Scan
EXPLAIN SELECT sum(v) FROM (SELECT v FROM fakty WHERE r >= 500000000000
                            ORDER BY r LIMIT 5000) s;                        -- T3: oczekiwany Index Scan
```

Jeśli plan nie zawiera oczekiwanego węzła, test nie mierzy tego, co mówi jego nazwa — popraw zapytanie przed pomiarem.

## ⏱️ 8. Pomiary

### 🤖 Ścieżka skryptowa

```powershell
.\lab.ps1 bench 7             # 7 przeplatanych serii w tle na VM (~85 min); log: /root/pgio/bench_run.log
.\lab.ps1 fetch               # kopiuje /root/pgio/results/* do results\
```

`bench/run_bench.sh` zapisuje jeden wiersz CSV na pomiar i odrzuca (`plan_ok=0`) każdy pomiar, w którego planie brakuje oczekiwanego węzła.
Szczegóły procedury: [METHODOLOGY_PL.md](METHODOLOGY_PL.md).

### ✋ Ścieżka ręczna

Jeden pomiar = przełączenie trybu, zimny cache, `EXPLAIN ANALYZE`. Powtórz dla każdego testu, trybu i serii:

```bash
MODE=io_uring                                     # sync | worker | io_uring
sudo -u postgres psql -Xc "ALTER SYSTEM SET io_method = '$MODE'"
systemctl stop postgresql-18; sync; echo 3 > /proc/sys/vm/drop_caches; systemctl start postgresql-18   # zimny cache
sudo -u postgres psql -Xc "show io_method"        # musi wypisać $MODE
sudo -u postgres psql -X <<'SQL'
SET max_parallel_workers_per_gather = 0;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) SELECT count(*), avg(v) FROM fakty;     -- T1a
SQL
```

Odczytaj `Execution Time`, `Buffers: shared read` i `I/O Timings: shared read` oraz sprawdź węzeł planu.
Pomiar **ciepły** (tylko T2, T3): wykonaj zapytanie raz, potem `EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)` bez restartu.
**VACUUM (T4):** przed każdym pomiarem odtwórz tabelę, wyczyść cache i zmierz czas:

```sql
DROP TABLE IF EXISTS fakty_vac;
CREATE TABLE fakty_vac WITH (autovacuum_enabled = off) AS SELECT * FROM fakty WHERE id <= 10000000;
CREATE INDEX fakty_vac_d_idx ON fakty_vac (d);
DELETE FROM fakty_vac WHERE id % 10 = 0;
CHECKPOINT;
-- tu restart z zimnym cache (stop, drop_caches, start), potem:
\timing on
VACUUM (VERBOSE) fakty_vac;          -- w każdym trybie oczekiwane 1 000 000 usuniętych krotek
```

Przeplataj tryby (`sync → worker → io_uring`, potem od nowa) zamiast robić wszystkie serie jednego trybu pod rząd,
a na końcu wykonaj `ALTER SYSTEM RESET io_method` i restart.

### 🔁 Opcjonalnie: test kontrolny z dyskiem danych na kontrolerze NVMe

Przenieś tylko dysk danych na emulowany kontroler NVMe (na hoście, VM wyłączona — `ssh root@192.168.56.40 systemctl poweroff`):

```bash
VBoxManage storageattach pgio --storagectl SATA --port 2 --medium none
VBoxManage storagectl pgio --name NVMe --add pcie --controller NVMe --portcount 1 --hostiocache off
VBoxManage storageattach pgio --storagectl NVMe --port 0 --device 0 --type hdd --medium "$DIR/pgio-data.vdi" --nonrotational on
VBoxManage startvm pgio --type headless
```

Po starcie `findmnt /pgdata` pokazuje `/dev/nvme0n1` (montowanie po etykiecie, nic więcej nie trzeba zmieniać). Potem:

| Ścieżka | Polecenie (na VM) |
|---|---|
| 🤖 | `grep -E '^(T1b\|T2)\|' /root/pgio/bench/tests.conf > /root/pgio/tests_control.conf`, potem<br>`CONF=/root/pgio/tests_control.conf RUNS=3 WARM_TESTS=none OUT_DIR=/root/pgio/control bash /root/pgio/bench/run_bench.sh` |
| ✋ | procedura pojedynczego pomiaru z punktu wyżej, tylko dla T1b, T2 i T4, 3 serie |

Wyniki kontrolne trzymaj osobno od głównego pomiaru (`OUT_DIR`); raport czyta je z `results/control_nvme/`.
Powrót: te same trzy kroki `storageattach`/`storagectl` w odwrotnej kolejności (`--storagectl NVMe --port 0 --medium none`,
`storagectl pgio --name NVMe --remove`, podłączenie dysku do `SATA` port 2).

## 📊 9. Raport

### 🤖 Ścieżka skryptowa

```powershell
python report\make_report.py --dry-run     # mediany na ekranie, nic nie zapisuje
python report\make_report.py               # docs\RESULTS*.md, docs\charts\*.svg, docs\index*.html
```

Opcjonalne, pisane ręcznie wnioski są brane z `report/findings_en.md` i `report/findings_pl.md`.

### ✋ Ścieżka ręczna

Wczytaj CSV do PostgreSQL i policz te same statystyki:

```sql
CREATE TABLE bench_raw (ts timestamp, series int, io_method text, test text, cache text, plan_ok int,
                        exec_ms numeric, shared_hit bigint, shared_read bigint, io_read_ms numeric, note text);
\copy bench_raw FROM 'raw_<znacznik_czasu>.csv' CSV HEADER
SELECT test, cache, io_method, count(*) AS liczba,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY exec_ms) AS mediana_ms,
       min(exec_ms) AS min_ms, max(exec_ms) AS max_ms
FROM bench_raw WHERE plan_ok = 1
GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;
```

## ↩️ Wycofanie

| Ścieżka | Polecenie |
|---|---|
| 🤖 | `.\lab.ps1 destroy pgio` — wyłącza, wyrejestrowuje i usuwa VM razem z dyskami |
| ✋ | `VBoxManage controlvm pgio poweroff`, potem `VBoxManage unregistervm pgio --delete` |

Gdy reguła zapory nie jest już potrzebna: `Remove-NetFirewallRule -DisplayName 'pgio-lab-ks-8000'` (jako administrator).
