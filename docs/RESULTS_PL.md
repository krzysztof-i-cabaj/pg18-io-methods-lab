# 📊 Wyniki — PostgreSQL 18 io_method: sync vs worker vs io_uring

[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-18.6-336791)]() [![io_method](https://img.shields.io/badge/io__method-sync_%7C_worker_%7C_io__uring-blue)]() [![Runs](https://img.shields.io/badge/Serie-7_przeplatanych-success)]() [![Plans](https://img.shields.io/badge/Kontrola_planu-każdy_pomiar-success)]()

> 🎯 Mediany dla każdego testu, stanu cache i `io_method`, wygenerowane z surowego CSV przez `report/make_report.py`. Wersja angielska: [RESULTS.md](RESULTS.md) · strona interaktywna: [GitHub Pages](https://krzysztof-i-cabaj.github.io/pg18-io-methods-lab/index_pl.html).

Źródło: `results/raw_20261015_152307.csv` · 147 przyjętych pomiarów · 0 odrzuconych (kontrola planu)

## 🔎 Najważniejsze wnioski

- **Bitmap Heap Scan i VACUUM były najszybsze z `sync` — na obu kontrolerach dysku.** Główny pomiar (SATA): Bitmap Heap Scan `sync` 11,0 s, `io_uring` 1,53× wolniej, `worker` 2,05× wolniej; VACUUM `sync` 15,2 s, `io_uring` 1,20×, `worker` 1,41× wolniej. Test kontrolny (NVMe): ta sama kolejność, większe różnice — Bitmap 5,9 s wobec 1,98× i 2,58× wolniej, VACUUM 10,8 s wobec 1,31× i 1,54× wolniej. Każdy tryb czyta tych samych 53 866 bloków, a VACUUM wykonuje tę samą pracę (1 000 000 usuniętych krotek, 163 935 zamrożonych stron).
- **Zysk io_uring przy pełnych skanach zależy od wirtualnego kontrolera dysku.** Na SATA io_uring był najszybszy: `Seq Scan` 1,09× i `Parallel Seq Scan` 1,21× szybciej niż `sync`. Na NVMe skan równoległy z io_uring trwał 66,0 s — 1,52× **wolniej** niż `sync` (43,5 s). Wyniku z SATA nie należy traktować jako ogólnej cechy io_uring.
- **`worker` przy zimnych danych nigdy nie był szybszy od `sync`.** Wyrównał `sync` przy skanie jednym procesem (58,4 wobec 59,1 s), a wszędzie indziej był wolniejszy, przy domyślnym `io_workers = 3` na 4 vCPU.
- **Index Scan się nie zmienia** (3,3–3,5 s): w PostgreSQL 18 asynchroniczne I/O obejmuje skany sekwencyjne, Bitmap Heap Scan i VACUUM ([informacje o wydaniu](https://www.postgresql.org/docs/18/release-18.html)); Index Scan czyta strony tabeli pojedynczo.
- **Ciepły cache nie pokazuje realnej różnicy.** T2 63–71 ms, T3 4,5–6,1 ms przy 0 blokach czytanych z dysku; rozrzut między pomiarami (do 22%) jest większy niż różnice między trybami.
- **Liczby są stabilne.** Główny pomiar: 7 przeplatanych serii, współczynnik zmienności 0,5–2,8% (T3 `worker` 9%). Test kontrolny: 3 serie, rozrzut max–min do 3% poza jednym skanem równoległym `sync` (52,3 s wobec 43,4–43,5 s).
- **Czego te wyniki nie mówią.** To jedna VM w VirtualBox (4 vCPU, 3,6 GB RAM, cache I/O hosta wyłączony) z domyślnymi `io_workers = 3`, `effective_io_concurrency = 16`. Drugi pomiar pokazuje, że emulowana warstwa dyskowa zmienia obraz, więc te liczby opisują to środowisko, a nie Twój serwer. Kolejne zmienne do sprawdzenia, po jednej naraz: `effective_io_concurrency`, `io_workers`, dysk fizyczny bez wirtualizacji.

## 🧭 Przegląd — główny pomiar (kontroler SATA)

![wykres](charts/overview_pl.svg)

## 🔁 Test kontrolny: dysk danych na kontrolerze NVMe

*zmieniona jedna zmienna: wirtualny kontroler dysku VM (SATA/AHCI → NVMe); 3 serie, zimny cache*

![wykres](charts/control_nvme_pl.svg)

Ta sama VM, dane, ustawienia PostgreSQL i zapytania; jedynie dysk danych przeniesiono z emulowanego kontrolera SATA (AHCI) na emulowany kontroler NVMe (na obu cache I/O hosta wyłączony). Źródło: `results/control_nvme/raw_20261015_164202.csv` · 27 pomiarów · 0 odrzuconych.

| Test | io_method | Mediana SATA | Mediana NVMe | SATA vs sync | NVMe vs sync |
|---|---|---:|---:|---:|---:|
| T1b | `sync` | 41,8 s | 43,5 s (n=3) | punkt odniesienia | punkt odniesienia |
| T1b | `worker` | 57,8 s | 58,4 s (n=3) | 1,38× wolniej | 1,34× wolniej |
| T1b | `io_uring` | 34,5 s | 66,0 s (n=3) | 1,21× szybciej | 1,52× wolniej |
| T2 | `sync` | 11,0 s | 5,91 s (n=3) | punkt odniesienia | punkt odniesienia |
| T2 | `worker` | 22,5 s | 15,3 s (n=3) | 2,05× wolniej | 2,58× wolniej |
| T2 | `io_uring` | 16,8 s | 11,7 s (n=3) | 1,53× wolniej | 1,98× wolniej |
| T4 | `sync` | 15,2 s | 10,8 s (n=3) | punkt odniesienia | punkt odniesienia |
| T4 | `worker` | 21,4 s | 16,7 s (n=3) | 1,41× wolniej | 1,54× wolniej |
| T4 | `io_uring` | 18,2 s | 14,2 s (n=3) | 1,20× wolniej | 1,31× wolniej |

## 🧊 Zimny cache — główny pomiar (restart PostgreSQL i wyczyszczony cache stron systemu przed każdym pomiarem)

![T1a · Seq Scan, 1 proces — zimny cache](charts/T1a_cold_pl.svg)

![T1b · Parallel Seq Scan, 2 workery — zimny cache](charts/T1b_cold_pl.svg)

![T2 · Bitmap Heap Scan, 1 dzień (~54 tys. wierszy) — zimny cache](charts/T2_cold_pl.svg)

![T3 · Index Scan, 5000 wierszy — zimny cache](charts/T3_cold_pl.svg)

![T4 · VACUUM, 10 mln wierszy, 10% usuniętych — zimny cache](charts/T4_cold_pl.svg)

## 🔥 Ciepły cache — główny pomiar (dane już w shared_buffers)

![T2 · Bitmap Heap Scan, 1 dzień (~54 tys. wierszy) — ciepły cache](charts/T2_warm_pl.svg)

![T3 · Index Scan, 5000 wierszy — ciepły cache](charts/T3_warm_pl.svg)

## 📋 Wszystkie liczby

Mediana, min, max i p90 z 7 przeplatanych serii. *vs sync* = stosunek median. *Odczyt I/O* = mediana `I/O Timings: shared read` z `EXPLAIN (ANALYZE, BUFFERS)`; przy równoległych workerach lub asynchronicznym I/O to suma oczekiwań wielu procesów, a nie czas zegarowy.

| Test | Cache | io_method | n | Mediana | Min | Max | p90 | vs sync | Odczyt I/O |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| T1a | zimny cache | `sync` | 7 | 59,1 s | 58,2 s | 61,4 s | 61,4 s | punkt odniesienia | 51,6 s |
| T1a | zimny cache | `worker` | 7 | 58,4 s | 57,2 s | 59,1 s | 59,1 s | ≈ sync | 30,7 s |
| T1a | zimny cache | `io_uring` | 7 | 54,2 s | 53,4 s | 55,0 s | 55,0 s | 1,09× szybciej | 15,6 s |
| T1b | zimny cache | `sync` | 7 | 41,8 s | 41,2 s | 42,0 s | 42,0 s | punkt odniesienia | 111,0 s |
| T1b | zimny cache | `worker` | 7 | 57,8 s | 57,5 s | 60,1 s | 60,1 s | 1,38× wolniej | 144,1 s |
| T1b | zimny cache | `io_uring` | 7 | 34,5 s | 34,2 s | 34,9 s | 34,9 s | 1,21× szybciej | 71,0 s |
| T2 | zimny cache | `sync` | 7 | 11,0 s | 10,8 s | 11,4 s | 11,4 s | punkt odniesienia | 3,08 s |
| T2 | zimny cache | `worker` | 7 | 22,5 s | 22,3 s | 22,9 s | 22,9 s | 2,05× wolniej | 21,0 s |
| T2 | zimny cache | `io_uring` | 7 | 16,8 s | 16,6 s | 16,9 s | 16,9 s | 1,53× wolniej | 14,4 s |
| T3 | zimny cache | `sync` | 7 | 3,34 s | 3,24 s | 3,49 s | 3,49 s | punkt odniesienia | 3,32 s |
| T3 | zimny cache | `worker` | 7 | 3,51 s | 3,23 s | 4,13 s | 4,13 s | 1,05× wolniej | 3,49 s |
| T3 | zimny cache | `io_uring` | 7 | 3,35 s | 3,23 s | 3,52 s | 3,52 s | ≈ sync | 3,33 s |
| T4 | zimny cache | `sync` | 7 | 15,2 s | 15,0 s | 16,2 s | 16,2 s | punkt odniesienia | — |
| T4 | zimny cache | `worker` | 7 | 21,4 s | 20,9 s | 22,0 s | 22,0 s | 1,41× wolniej | — |
| T4 | zimny cache | `io_uring` | 7 | 18,2 s | 18,0 s | 18,5 s | 18,5 s | 1,20× wolniej | — |
| T2 | ciepły cache | `sync` | 7 | 67,4 ms | 59,0 ms | 71,9 ms | 71,9 ms | punkt odniesienia | 0,0 ms |
| T2 | ciepły cache | `worker` | 7 | 63,4 ms | 56,5 ms | 68,5 ms | 68,5 ms | 1,06× szybciej | 0,0 ms |
| T2 | ciepły cache | `io_uring` | 7 | 70,9 ms | 61,1 ms | 81,4 ms | 81,4 ms | 1,05× wolniej | 0,0 ms |
| T3 | ciepły cache | `sync` | 7 | 6,1 ms | 4,1 ms | 6,9 ms | 6,9 ms | punkt odniesienia | 0,0 ms |
| T3 | ciepły cache | `worker` | 7 | 4,5 ms | 3,6 ms | 6,6 ms | 6,6 ms | 1,35× szybciej | 0,0 ms |
| T3 | ciepły cache | `io_uring` | 7 | 5,7 ms | 4,9 ms | 6,5 ms | 6,5 ms | 1,06× szybciej | 0,0 ms |

## 🖥️ Środowisko

| | |
|---|---|
| **PostgreSQL** | PostgreSQL 18.6 |
| **OS** | Rocky Linux release 9.8, kernel 5.14.0-687.57.1.el9_8.x86_64 |
| **CPU** | AMD Ryzen 9 8940HX with Radeon Graphics · 4 vCPU |
| **RAM** | 3,6 GB · shared_buffers 1 GB |
| **Dysk** | ? · VirtualBox ? · cache I/O hosta wyłączony |
| **I/O** | effective_io_concurrency 16 · io_workers 3 · io_combine_limit 128 kB |
| **Dane** | fakty: 100 mln wierszy, 13 GB + 4,9 GB indeksów |

## 🔗 Metoda

Jak dobrano i uruchomiono testy: [METHODOLOGY_PL.md](METHODOLOGY_PL.md) · jak powtórzyć: [INSTALL_PL.md](INSTALL_PL.md) · surowe dane: [`results/`](../results/).

---

© KCB Consulting · Krzysztof Cabaj · wygenerowano 2026-10-15
