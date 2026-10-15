# 🧪 Metodologia

[![Zmienna](https://img.shields.io/badge/Zmienna-tylko_io__method-blue)]()
[![Serie](https://img.shields.io/badge/Serie-7_przeplatanych-blueviolet)]()
[![Kontrola](https://img.shields.io/badge/Kontrola_planu-każdy_pomiar-success)]()

> 🎯 Jak powstały liczby w tym repozytorium — i czego mogą, a czego nie mogą powiedzieć.
> 🇬🇧 [English version](METHODOLOGY.md)

---

## 🎯 Pytanie

Jak `io_method` w PostgreSQL 18 — `sync`, `worker`, `io_uring` — wpływa na operacje czytające dane, które **nie** mieszczą się
w pamięci, na tej samej VM, tej samej binarce, tych samych danych i tej samej konfiguracji?

## 🔒 Co jest stałe

| Element | Wartość |
|---|---|
| Binarka | PostgreSQL 18.6 (PGDG), zbudowany `--with-liburing` |
| Dane | tabela `fakty`, 100 mln wierszy, 13 GB tabeli + 4,9 GB indeksów, generowana z `setseed(0.42)` |
| Konfiguracja | `shared_buffers = 1GB`, `track_io_timing = on`, wszystkie `io_*` i `*_io_concurrency` domyślne dla PG18 |
| VM | 4 vCPU, 3,6 GB RAM, dane na dysku VDI o stałym rozmiarze, host I/O cache wyłączony, żadna inna VM nie działa |
| Tabela | `autovacuum_enabled = off` na czas pomiaru (dane statyczne) |

**Jedyna zmiana między trybami:** `ALTER SYSTEM SET io_method = …` i restart.

## 📐 Testy

Zdefiniowane w [`bench/tests.conf`](../bench/tests.conf). Każdy test deklaruje węzeł planu, który ma mierzyć.

| Test | Zapytanie | Oczekiwany węzeł | Czytane dane |
|---|---|---|---|
| T1a | `count(*), avg(v)` po całej tabeli, `max_parallel_workers_per_gather = 0` | `Seq Scan` | 13 GB sekwencyjnie |
| T1b | to samo, domyślna równoległość | `Parallel Seq Scan` | 13 GB sekwencyjnie, 3 procesy |
| T2 | jeden dzień z `d` (~54,5 tys. wierszy), bez równoległości | `Bitmap Heap Scan` | ~54 tys. stron rozrzuconych po 13 GB |
| T3 | 5 000 kolejnych wartości `r` przez `ORDER BY r LIMIT 5000` | `Index Scan` | ~5 tys. losowych stron tabeli |
| T4 | `VACUUM (VERBOSE)` kopii 10 mln wierszy po usunięciu 10 % | — | ~1,3 GB tabeli + indeks |

T2 obejmuje jeden dzień, bo przy tych danych i `random_page_cost = 4` planer sam wybiera `Bitmap Heap Scan` tylko dla
takiego zakresu (3–14 dni → `Index Scan`, ≥ 30 dni → `Seq Scan`). Żadne ustawienia planera nie są wymuszane.

## 🛡️ Kontrola planu

Każdy pomiar to `EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, FORMAT JSON)` ze sprawdzeniem, czy oczekiwany węzeł jest w wykonanym
planie. Wynik zapisuje się z `plan_ok = 0/1`; **wiersze z `plan_ok = 0` nie trafiają do raportu**.
Wykonane plany z pierwszej serii są w `results/plans_*/`.

## ❄️ Zimny i 🔥 ciepły cache

- **Zimny:** przed każdym pomiarem — stop PostgreSQL, `sync`, `echo 3 > /proc/sys/vm/drop_caches`, start PostgreSQL.
  Przy wyłączonym host I/O cache VirtualBoksa odczyty naprawdę trafiają do NVMe hosta.
- **Ciepły:** jedno niemierzone wykonanie rozgrzewające, potem pomiar. Tylko dla **T2 i T3**, których strony mieszczą się w pamięci.
  Dla T1 tabela 13 GB to 3,6× RAM VM; w próbie „ciepły” `Seq Scan` trwał 53,7 s wobec 58,9 s na zimno, więc ciepły pełny skan
  jest w praktyce zimny i nie był mierzony osobno.
- **T4 (VACUUM):** tylko zimny; tabela jest odtwarzana identycznie (`CREATE TABLE AS`, indeks, `DELETE` 10 %, `CHECKPOINT`) przed każdym przebiegiem.

## 🔁 Serie

7 serii. W każdej serii tryby idą w kolejności `sync → worker → io_uring`, więc ewentualny dryf hosta w czasie
(temperatura, aktywność w tle) rozkłada się na wszystkie tryby, zamiast obciążać jeden z nich.

## 📊 Raportowane wartości

Dla każdej kombinacji test × cache × tryb: **mediana**, minimum i maksimum czasu wykonania z 7 serii oraz mediana
`Shared Read Blocks` i czasu odczytu I/O z `track_io_timing`. Przyspieszenia to ilorazy median względem `sync`.

Surowe dane: `results/raw_20261015_152307.csv` (główny pomiar). W tym pliku kolumna `exec_ms` w **wierszach T4 zawiera mikrosekundy**
(zapis `run_bench.sh` 1.0); raport je przelicza, a `run_bench.sh` 1.1 zapisuje milisekundy.

## 🔁 Test kontrolny — dysk danych na kontrolerze NVMe

Główny pomiar pokazał przewagę `sync` nad asynchronicznym I/O przy Bitmap Heap Scan i VACUUM. Przed publikacją zmieniono jedną
zmienną, by sprawdzić, czy powodem jest emulowany kontroler SATA (AHCI): **dysk danych** przeniesiono na emulowany kontroler **NVMe**
(`useHostIOCache=false`, nierotacyjny). Dysk systemowy, dane, ustawienia PostgreSQL i zapytania zostały te same; w gościu
`/pgdata` jest montowany po etykiecie, więc nowa nazwa urządzenia (`nvme0n1`) niczego nie zmienia. Scheduler pozostał `mq-deadline`;
głębokość kolejki widziana przez gościa (`nr_requests`) to 256 na NVMe wobec 64 na SATA — to część zmiany kontrolera.

Zakres: T1b, T2, T4, zimny cache, 3 przeplatane serie (27 pomiarów, 0 odrzuconych) — `results/control_nvme/`.
Wynik: `sync` pozostał najszybszy dla T2 i T4; przewaga io_uring w T1b się odwróciła (1,21× szybciej na SATA, 1,52× wolniej na NVMe).

## ⚠️ Ograniczenia

- Jedna VM na laptopie (VirtualBox, wirtualny SATA na NVMe) — liczby bezwzględne **nie** odpowiadają produkcyjnym macierzom;
  porównujemy tryby między sobą, nie z innymi systemami.
- `EXPLAIN ANALYZE` dodaje niewielki narzut (pomiar czasu per węzeł wyłączony, by go ograniczyć).
- `io_uring` wymagał zmiany ustawienia jądra (`kernel.io_uring_disabled = 0`); RHEL/Rocky 9 domyślnie go wyłączają.
- Tylko wartości domyślne PG18 (`io_workers = 3`, `effective_io_concurrency = 16`, `io_combine_limit = 128kB`); strojenie poza zakresem.
