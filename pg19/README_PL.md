# 🐘 pg19 — PostgreSQL 19 kontra 18 na tej samej VM: REPACK (CONCURRENTLY), klucze obce, pg_upgrade --check

[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-18.6_%E2%86%92_19.0-336791?logo=postgresql&logoColor=white)]()
[![OS](https://img.shields.io/badge/Rocky_Linux-9.8-orange)]()
[![VM](https://img.shields.io/badge/VM-pgio_(to_repo)-blue)](../README_PL.md)
[![Serie](https://img.shields.io/badge/Serie-R_27_%C2%B7_F_20_%C2%B7_U_ok-success)]()
[![Licencja](https://img.shields.io/badge/Licencja-MIT-F1C40F)](../LICENSE)

> 🎯 Ciąg dalszy na VM `pgio` z tego repozytorium: PostgreSQL 19.0 zainstalowany obok 18.6 na tym samym dysku i trzy
> obietnice z ogłoszenia PostgreSQL 19 sprawdzone pomiarem. 🇬🇧 [English version](README.md)

**Strona interaktywna (REPACK):** <https://krzysztof-i-cabaj.github.io/pg18-io-methods-lab/pg19/index_pl.html> ·
Markdown: [docs/RESULTS_PL.md](docs/RESULTS_PL.md) · krok po kroku: [docs/RUN_PL.md](docs/RUN_PL.md)

## 📊 Wyniki

**R · REPACK (CONCURRENTLY) kontra VACUUM FULL.** Tabela 2,3 GB (20 mln wierszy, połowa usunięta) jest przepisywana,
a w tym czasie 1, 4 albo 8 sesji `pgbench` cały czas ją aktualizuje. „Zapisy stoją” = sekundy z 0 transakcji;
mediana z 3 serii, PostgreSQL 19.0.

| Sesje zapisujące | `VACUUM FULL`: zapisy stoją | `REPACK (CONCURRENTLY)`: zapisy stoją | Czas REPACK | Najdłuższe czekanie VF / REPACK |
|---|---:|---:|---:|---:|
| 1 (~1 700–1 900 tps) | 11 s | **0 s** | 13,6 s | 12,3 s / **0,1 s** |
| 4 (~5 700 tps) | 13 s | **5 s** | 32,5 s | 13,7 s / 6,1 s |
| 8 (~7 600–9 400 tps) | **15 s** (15–21) | 18 s (18–19) | 93,1 s | 16,1 s / 19,6 s |

- **REPACK (CONCURRENTLY) to nie „zero przestoju”:** w trakcie kopiowania zapisy idą, ale faza końcowa bierze
  `ACCESS EXCLUSIVE`, a jej długość rośnie z ruchem: 0 → 5 → 18 s. Dokumentacja mówi, że blokada jest „zwykle krótka,
  zależnie od liczby zmian”; tu widać, ile to „krótko” znaczyło.
- **Przy 8 sesjach REPACK blokował zapisy dłużej niż VACUUM FULL** (18 s wobec 15 s). 4 vCPU były zajęte w całości,
  więc czytaj to jako „porównywalnie albo gorzej”, nie jako dokładną różnicę.
- **Sama wersja nie zmienia starego polecenia:** `VACUUM FULL` w 18 i 19 blokuje tak samo (14 i 13 s).

**F · klucz obcy przy masowym INSERT** (5 mln wierszy do tabeli z FK do tabeli nadrzędnej 100 tys. wierszy, 5 serii):
PG18 **27,6 s** → PG19 **14,4 s** = **1,92×** szybciej; sama część FK 2,36× (22,6 s → 9,6 s). Bez FK obie wersje
równo (5,0 i 4,9 s). Ogłoszenie mówi „prawie 2×” — dla tego scenariusza potwierdzone.

**U · `pg_upgrade --check` 18 → 19** (copy i link): `*Clusters are compatible*`, wszystkie kontrole `ok` — dla prostego
klastra bez rozszerzeń.

## 🎯 Cel

Sprawdzić trzy obietnice z ogłoszenia PostgreSQL 19 na własnym sprzęcie zamiast powtarzać listę nowości:
`REPACK (CONCURRENTLY)` bez blokowania, „prawie 2×” szybsze sprawdzanie kluczy obcych i to, co `pg_upgrade --check`
powie o klastrze PostgreSQL 18 z głównego labu. Zmienia się tylko wersja serwera (albo polecenie); VM, dysk
i konfiguracja zostają te same.

## 🧭 Zakres

| W zakresie | Poza zakresem |
|---|---|
| PG19 z PGDG obok PG18 na VM `pgio` (port 5433, `/pgdata/19/data`, te same ustawienia) | Replikacja (`WAIT FOR LSN`, sekwencje w replikacji logicznej) |
| R: `VACUUM FULL` (18, 19) kontra `REPACK (CONCURRENTLY)` (19) przy 1/4/8 sesjach zapisujących | Zmiany planera, domyślne `io_method` w 19 |
| F: `INSERT … SELECT` 5 mln wierszy z FK i bez, `jit = off` w obu | Tabele z indeksami, WAL z replikacją, triggery aplikacji |
| U: `pg_upgrade --check` (copy i link) z klastra 18 | Prawdziwy upgrade; klastry z rozszerzeniami |

## 📁 Struktura katalogu

```text
pg19/
├── lab.ps1                  # sterowanie z hosta: status, start, install, preflight, push, trial, run, progress, fetch, stop
├── guest/
│   ├── preflight.sh         # karta środowiska (tylko odczyt)
│   └── install_pg19.sh      # PG19 z PGDG obok PG18 (DRY_RUN=1 = podgląd)
├── bench/
│   ├── run_all.sh           # orkiestracja: SUITE=all|repack|fk|upgrade|clients, TRIAL=1, DRY_RUN=1
│   ├── repack_test.sh       # test R (+ oś czasu tps co sekundę)
│   ├── writer.sql           # klient pgbench: UPDATE losowego wiersza po PK
│   ├── fk_test.sh           # test F
│   ├── upgrade_check.sh     # test U
│   └── common.sh            # wybór klastra, restart na zimno
├── sql/                     # 10_bloat_table.sql (R), 20_fk_tables.sql (F)
├── report/                  # summarize.py, timeline_stats.py, build_explainer.py + szablony strony (PL, EN)
├── results/                 # surowe CSV, osie czasu, plany, karta środowiska, run.log, SUMMARY_*.md
└── docs/                    # RESULTS, RUN (EN + PL)
```

Strona interaktywna jest budowana do [`../docs/pg19/`](../docs/pg19/) (GitHub Pages).

## 📋 Wymagania

VM `pgio` zbudowana i przygotowana w głównym labie ([README_PL](../README_PL.md), etapy 1–3): Rocky Linux 9.8,
PostgreSQL 18.6, dysk danych na `/pgdata`. Do tego: internet z VM (pakiety PGDG), ≥ 12 GB wolnego na `/pgdata`,
Windows 11 + PowerShell 7 + klucz OpenSSH (droga skryptowa), Python 3.8+ do raportów.

## 🚀 Uruchomienie

Każdy etap ma dwie drogi: 🤖 **skryptową** (`lab.ps1`, z katalogu `pg19`) i ✋ **ręczną** (`ssh`, `scp`, `dnf`, `psql`).
Obie opisuje [docs/RUN_PL.md](docs/RUN_PL.md).

| # | Etap | 🤖 Droga skryptowa | ✋ Droga ręczna |
|---|---|---|---|
| 1 | VM działa | `.\lab.ps1 status`, `.\lab.ps1 start` | [RUN_PL §1](docs/RUN_PL.md#1-start-vm) |
| 2 | PostgreSQL 19 obok 18 | `.\lab.ps1 install -DryRun`, potem `install` | [RUN_PL §2](docs/RUN_PL.md#2-instalacja-postgresql-19-obok-18) |
| 3 | Karta środowiska | `.\lab.ps1 preflight` | [RUN_PL §3](docs/RUN_PL.md#3-karta-środowiska) |
| 4 | Skrypty na VM | `.\lab.ps1 push` | [RUN_PL §4](docs/RUN_PL.md#4-skrypty-na-vm) |
| 5 | Próba (małe tabele, ~1 min) | `.\lab.ps1 trial`, `progress`, `fetch` | [RUN_PL §5](docs/RUN_PL.md#5-próba) |
| 6 | Część 1: R, F, U (~30 min) | `.\lab.ps1 run`, `progress`, `fetch` | [RUN_PL §6](docs/RUN_PL.md#6-część-1-r-f-u) |
| 7 | Część 2: REPACK przy 1/4/8 sesjach (~26 min) | `.\lab.ps1 run -Suite clients -RunsR 3` | [RUN_PL §7](docs/RUN_PL.md#7-część-2-repack-przy-148-sesjach) |
| 8 | Kontrola: VACUUM FULL przy 1/8 sesjach (~16 min) | `.\lab.ps1 run -Suite clients -RunsR 3 -ExtraEnv 'VARIANT_C=vacuum_full CLIENTS_LIST=1,8'` | [RUN_PL §8](docs/RUN_PL.md#8-kontrola-vacuum-full-przy-1-i-8-sesjach) |
| 9 | Raport i strona | `python report\summarize.py`, `python report\build_explainer.py …` | [RUN_PL §9](docs/RUN_PL.md#9-raport-i-strona) |

## ✅ Weryfikacja wyniku

- `run.log` kończy się `KONIEC suite=… fail=0`; każdy wiersz CSV ma `ok=1`.
- R: tabela po operacji ma połowę wierszy; F: tabela docelowa ma `ROWS_F` wierszy.
- `python report\summarize.py --ts <ts>` pokazuje `Odrzucone serie (ok=0): 0`.

## ↩️ Rollback

- Dane testowe: `DROP DATABASE labtest` w obu klastrach (tabela `fakty` głównego labu jest w bazie `postgres`, nietknięta).
- PostgreSQL 19: `systemctl stop postgresql-19; dnf -y remove postgresql19-server postgresql19-contrib postgresql19 postgresql19-libs;
  rm -rf /pgdata/19 /etc/systemd/system/postgresql-19.service.d; systemctl daemon-reload`. PG18 wraca do stanu sprzed labu.

## ⚠️ Ważne uwagi

- **Jedna VM** (4 vCPU, 3,6 GB RAM, wirtualny NVMe na dysku laptopa). Sekundy dotyczą tej maszyny; przenosi się kształt:
  gdzie stoją zapisy i jak to rośnie z ruchem.
- Obciążenie w R to syntetyczny `UPDATE` jednego wiersza po kluczu głównym. Aplikacja z dłuższymi transakcjami czekałaby
  inaczej, zwłaszcza w fazie końcowej REPACK.
- Z dokumentacji, czego liczby nie pokażą: `REPACK (CONCURRENTLY)` **nie jest MVCC-safe** (`VACUUM FULL` jest),
  wymaga klucza głównego albo replica identity na indeksie, zużywa slot z `max_repack_replication_slots` (domyślnie 5)
  i przerywa się powyżej ~104 mln równoległych zmian.
- Ustawienia domyślne, które różnią 18 i 19 na tej VM (`jit`, `io_workers`, `log_lock_waits`, …): [RUN_PL §3](docs/RUN_PL.md#3-karta-środowiska).

## 🔗 Źródła

[PostgreSQL 19 Released!](https://postgresql.org/about/news/postgresql-19-released-3449) ·
[Release notes 19](https://www.postgresql.org/docs/19/release-19.html) ·
[REPACK](https://www.postgresql.org/docs/19/sql-repack.html) ·
[pg_upgrade](https://www.postgresql.org/docs/19/pgupgrade.html)

## 👤 Autor

Krzysztof Cabaj · KCB Consulting · lab zbudowany i zmierzony z Claude Code (Agentic DBA Lab #7) ·
Licencja: [MIT](../LICENSE)
