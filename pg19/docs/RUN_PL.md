# 📗 RUN — PostgreSQL 19 kontra 18 krok po kroku (skryptem i ręcznie)

[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-18.6_%2B_19.0-336791)]()
[![VM](https://img.shields.io/badge/VM-pgio_NVMe-orange)]()
[![Drogi](https://img.shields.io/badge/Drogi-skrypt_%7C_r%C4%99cznie-blueviolet)]()
[![Pomiar](https://img.shields.io/badge/Pomiar-2026--11--23-success)]()

> 🎯 Każdy krok: 🤖 polecenie skryptowe, ✋ ręczny odpowiednik, po co jest i co wyszło w naszym przebiegu (23.11.2026).
> 🇬🇧 [English version](RUN.md) · wyniki i interpretacja: [RESULTS_PL.md](RESULTS_PL.md)

Polecenia skryptowe uruchamiasz w PowerShell 7 z katalogu `pg19` tego repozytorium. Polecenia ręczne zakładają VM
z głównego labu: `pgio`, `192.168.56.40`, logowanie na root Twoim kluczem SSH. Na VM lab leży w `/root/pg19lab`.

## 🧭 Decyzje przed startem

| Decyzja | Wybór | Dlaczego |
|---|---|---|
| Kontroler dysku danych | **NVMe** (jak po teście kontrolnym głównego labu) | bez przebudowy = jedna różnica mniej; dla 18 kontra 19 liczy się tylko „ten sam kontroler” |
| PG19 na tej samej VM | tak, obok PG18 (port 5433, `/pgdata/19/data`) | ten sam sprzęt, system i dysk — różni się tylko wersja serwera |
| Host wolny | bez innych VM i nagrań | zaburzają I/O; `lab.ps1 start` odmawia, gdy działają inne VM (`-Force` wymusza) |

## 1. Start VM

- 🤖 `.\lab.ps1 status`, potem `.\lab.ps1 start` (start bez okna, czekanie na SSH, wypisuje kontrolery dysków).
- ✋ `& 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe' startvm pgio --type headless`, potem `ssh root@192.168.56.40 hostname`.
- **U nas:** kontrolery `SATA` (system) i `NVMe` (dysk danych), SSH odpowiada.

## 2. Instalacja PostgreSQL 19 obok 18

- 🤖 `.\lab.ps1 install -DryRun` (podgląd: wolne miejsce ≥ 12 GB, działający PG18, wolny port 5433, plan), potem `.\lab.ps1 install`.
  Skrypt `guest/install_pg19.sh` idzie na VM przez stdin SSH i tam nie zostaje.
- ✋ Na VM jako root:

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
  systemctl start postgresql-19          # bez "enable": przy boocie startuje tylko PG18
  ```

- **U nas:** pakiet repo PGDG z października nie znał jeszcze PG19 (`42.0-70`); instalacja z URL podbiła go do `42.0-71`.
  Zainstalowane `postgresql19-*-19.0-1PGDG.rhel9.8`, `data_checksums on`, `io_method worker`. Miejsca było na styk
  (tabela R potrzebuje ~4,5 GB na klaster razem z przepisaniem i WAL), więc `repack_test.sh` usuwa `bloat_t` po każdej serii.

## 3. Karta środowiska

- 🤖 `.\lab.ps1 preflight` → `results\preflight_<ts>.txt` (tylko odczyt).
- ✋ `Get-Content -Raw guest\preflight.sh | ssh root@192.168.56.40 "tr -d '\r' | bash -s" > results\preflight_reczny.txt`
- **U nas:** VirtualBox 7.2.22, Rocky 9.8, 4 CPU, 3655 MB RAM, `/pgdata` na `nvme0n1` (mq-deadline, `nr_requests 256`).
  Domyślne ustawienia, którymi różnią się wersje:

  | Ustawienie | PG18 | PG19 | Wpływ na testy |
  |---|---|---|---|
  | `jit` | on | **off** | test F ustawia `jit = off` w obu |
  | `io_workers` / `io_min_workers`–`io_max_workers` | 3 (stałe) | **2–8 (autoskalowanie)** | część „nowej wersji”, nie wyrównujemy |
  | `log_lock_waits` | off | **on** | tylko log; test R daje w PG19 wpisy o czekaniu na blokady |
  | `max_locks_per_transaction` | 64 | **128** | bez wpływu |
  | `default_toast_compression` | pglz | **lz4** | bez wpływu (kolumna 64 znaki, bez TOAST) |
  | `max_repack_replication_slots` | — | **5** | nowe; REPACK CONCURRENTLY używa slotu |
  | `effective_wal_level` | — | **replica** | nowe; przy `wal_level = replica` |

## 4. Skrypty na VM

- 🤖 `.\lab.ps1 push` (kopiuje `bench\` i `sql\`, usuwa CR, kontrola składni `bash -n`).
- ✋

  ```powershell
  ssh root@192.168.56.40 "mkdir -p /root/pg19lab/results && chmod 755 /root /root/pg19lab"
  scp -r bench sql root@192.168.56.40:/root/pg19lab/
  ssh root@192.168.56.40 "sed -i 's/\r$//' /root/pg19lab/bench/* /root/pg19lab/sql/*; chmod -R a+rX,go-w /root/pg19lab; bash -n /root/pg19lab/bench/*.sh && echo OK"
  ```

## 5. Próba

- 🤖 `.\lab.ps1 trial -DryRun` (plan), `.\lab.ps1 trial`, potem `.\lab.ps1 progress` aż do linii `KONIEC`, na końcu `.\lab.ps1 fetch`.
- ✋ Pomiar startuje przez `systemd-run`, więc nie zależy od sesji SSH:

  ```powershell
  ssh root@192.168.56.40 "systemd-run --unit=pg19lab-run --collect --setenv=SUITE=all --setenv=TRIAL=1 /bin/bash -c 'bash /root/pg19lab/bench/run_all.sh >> /root/pg19lab/run.log 2>&1'"
  ssh root@192.168.56.40 "tail -n 25 /root/pg19lab/run.log"                 # postęp
  scp -r root@192.168.56.40:/root/pg19lab/results/* results\                # pobranie wyników
  scp root@192.168.56.40:/root/pg19lab/run.log results\run.log
  ```

- **Po co:** wszystkie trzy testy na małych tabelach (R 400 tys. wierszy, F 200 tys.) wyłapują błędy skryptów przed godziną
  pomiaru i pokazują, czy `REPACK (CONCURRENTLY)` działa przy `wal_level = replica` — działa.
- **Dwa błędy wyłapane tutaj:** (1) `systemd-run -p StandardOutput=append:/root/...` kończył się `status=209/STDOUT` — systemd
  sam otwiera plik, a SELinux mu nie pozwala; teraz log otwiera `bash -c '… >> run.log'`. Diagnoza:
  `journalctl -u pg19lab-run --no-pager -n 30`. (2) „tps w trakcie” liczone z sekund, których środek wypada w oknie operacji —
  przy operacji poniżej sekundy wychodziły bzdury; teraz liczy się każda sekunda nachodząca na okno.

## 6. Część 1: R, F, U

- 🤖 `.\lab.ps1 run` (R 3 serie × PG18 VF, PG19 VF, PG19 REPACK CONC. na 20 mln wierszy; F 5 serii × PG18, PG19 na 5 mln,
  kolejność zmienna; U raz), `.\lab.ps1 progress`, `.\lab.ps1 fetch`. Jeden test: `.\lab.ps1 run -Suite repack -RunsR 3` (też `fk`, `upgrade`).
- ✋ Jak w kroku 5, ale `--setenv=SUITE=all --setenv=RUNS_R=3 --setenv=RUNS_F=5` zamiast `TRIAL=1`.
- **U nas** (`20261123_183133_full`): `KONIEC suite=all fail=0`, 27 min, R 9/9 i F 20/20 serii `ok=1`.

## 7. Część 2: REPACK przy 1/4/8 sesjach

- **Po co:** w części 1 REPACK blokował zapisy na 5–6 s na końcu. Hipoteza: pod blokadą nanosi zmiany zebrane w trakcie,
  więc więcej zapisów = dłuższa blokada. Ten sam REPACK przy 1, 4 i 8 sesjach zapisujących, 3 serie, kolejność 1-4-8 / 8-4-1 / 1-4-8;
  „4 sesje” powtarzają część 1 jako kontrolę powtarzalności.
- 🤖 `.\lab.ps1 run -Suite clients -RunsR 3`
- ✋ `--setenv=SUITE=clients --setenv=RUNS_R=3` (opcjonalnie `--setenv=CLIENTS_LIST=1,4,8`).
- **U nas** (`20261123_192156_full`, 26 min, 9/9 `ok=1`): czas 13,6 / 32,5 / 93,1 s, zapisy stoją **0 / 5 / 18 s**,
  najdłuższe czekanie 0,1 / 6,1 / 19,6 s. Hipoteza się trzyma.

## 8. Kontrola: VACUUM FULL przy 1 i 8 sesjach

- **Po co:** w części 1 VACUUM FULL był tylko przy 4 sesjach; zdanie „REPACK przy 8 sesjach gorszy od VACUUM FULL” wymaga
  tego samego obciążenia po obu stronach.
- 🤖 `.\lab.ps1 run -Suite clients -RunsR 3 -ExtraEnv 'VARIANT_C=vacuum_full CLIENTS_LIST=1,8'`
- ✋ `--setenv=SUITE=clients --setenv=RUNS_R=3 --setenv=VARIANT_C=vacuum_full --setenv=CLIENTS_LIST=1,8`
- **U nas** (`20261123_194837_full`, 16 min, `fail=0`): zapisy stoją 11 s przy 1 sesji, **15 s** przy 8 (15–21).
- **Lekcja:** po pierwszej serii (21 s) wyglądało, że REPACK przy 8 sesjach wygrywa; mediana z 3 serii mówi odwrotnie
  (VF 15 s, REPACK 18 s).
- Nowe skrypty na VM wgrywaj dopiero po końcu poprzedniego pomiaru: bash czyta działający skrypt w trakcie wykonania.

## 9. Raport i strona

```powershell
python report\summarize.py --ts 20261123_183133_full --out results\SUMMARY_20261123_183133_full.md   # mediany
python report\timeline_stats.py 20261123_183133_full                                                # gdzie w czasie stoją zapisy
ssh root@192.168.56.40 'grep -h "acquired.*after" /pgdata/19/data/log/*.log'                       # czekania zalogowane przez PG19
python report\build_explainer.py --part1 20261123_183133_full --part2 20261123_192156_full --control 20261123_194837_full `
  --out ..\docs\pg19\index_pl.html                                                                  # strona PL
python report\build_explainer.py --part1 20261123_183133_full --part2 20261123_192156_full --control 20261123_194837_full `
  --template report\explainer_template_en.html --out ..\docs\pg19\index.html                        # strona EN
```

## 🏁 Stan po pomiarze / Rollback

- PG18 aktywny (jak przy boocie); PG19 zainstalowany, zatrzymany, bez autostartu. Baza `labtest` w obu klastrach. `/pgdata`: 17 GB wolnego.
- Wyłączenie VM: `.\lab.ps1 stop`. Pełne cofnięcie PG19 i danych testowych: [README_PL, sekcja Rollback](../README_PL.md).
