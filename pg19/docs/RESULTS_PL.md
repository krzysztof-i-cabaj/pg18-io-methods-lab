# 🔬 WYNIKI — PostgreSQL 19 kontra 18: REPACK, klucze obce, pg_upgrade --check

[![Pomiar](https://img.shields.io/badge/Pomiar-23.11.2026-blue)]()
[![Serie](https://img.shields.io/badge/Serie-R_27_%C2%B7_F_20_ok-success)]()
[![VM](https://img.shields.io/badge/VM-pgio_4vCPU_3.6GB_NVMe-orange)]()
[![PG](https://img.shields.io/badge/PostgreSQL-18.6_vs_19.0-336791)]()

> 🎯 Co wyszło z trzech testów, jak to czytać i czego te liczby nie mówią. Surowe dane: `../results/`
> (`*_20261123_183133_full*` część 1, `*_192156_full*` część 2, `*_194837_full*` kontrola), tabele median:
> `../results/SUMMARY_*.md`. 🇬🇧 [English version](RESULTS.md) · strona interaktywna:
> <https://krzysztof-i-cabaj.github.io/pg18-io-methods-lab/pg19/index_pl.html>

## 📌 Najważniejsze

1. **Klucze obce: „prawie 2×” potwierdzone** — masowy INSERT 5 mln wierszy z FK: PG18 27,6 s → PG19 14,4 s (**1,92×**);
   sam koszt sprawdzania FK spadł 2,36×. Rozrzut serii < 7%.
2. **`REPACK (CONCURRENTLY)` to nie „zero przestoju”** — zapisy idą w trakcie kopiowania, ale na końcu stoją; ten koniec
   rośnie z ruchem: **0 / 5 / 18 s** przy 1 / 4 / 8 sesjach. Przy 8 sesjach `VACUUM FULL` blokował krócej (15 s).
3. **`pg_upgrade --check` 18 → 19: `Clusters are compatible`** (copy i link) — prosty klaster bez rozszerzeń nie trafia
   na żadną z nowych blokad.

## 🧹 Test R — REPACK (CONCURRENTLY) kontra VACUUM FULL

Tabela `bloat_t`: 20 mln wierszy, po `DELETE` połowy i zwykłym `VACUUM` 2404 MB (2,3 GB, połowa pusta). W trakcie operacji
`pgbench` cały czas robi `UPDATE` losowego wiersza po kluczu głównym. 3 serie każdego wariantu.

### Część 1: 4 sesje, PG18 i PG19

| Wariant | Czas operacji | Zapisy w trakcie (tps) | Sekundy z 0 tps | Najdłuższe czekanie zapisu | Tabela po |
|---|---|---|---|---|---|
| PG18 `VACUUM FULL` | **14,6 s** (14,2–14,8) | 731 | **14** (13–14) | **14,6 s** | 1211 MB |
| PG19 `VACUUM FULL` | **13,7 s** (13,6–13,7) | 752 | **13** | **13,7 s** | 1210 MB |
| PG19 `REPACK (CONCURRENTLY)` | **32,7 s** (32,6–34,3) | **3198** | **5** (5–6) | **6,2 s** (5,8–6,8) | 1218 MB |

Seria 1 co sekundę (`timeline_19_repack_concurrently_1.csv`): 0–9 s ok. 2000 tps (kopiowanie), 10–26 s 4000–6300 tps,
**27–31 s zero**, 32 s zaległe transakcje (czekały 5818 ms), od 33 s 6600–9000 tps.

### Część 2 i kontrola: ruch 1 / 4 / 8 sesji (PG19)

| Sesje (zapisy/s przed) | VACUUM FULL: zapisy stoją | REPACK (CONC.): zapisy stoją | Czas REPACK | Najdłuższe czekanie VF / REPACK |
|---|---|---|---|---|
| 1 (~1 700–1 900) | 11 s | **0 s** | 13,6 s | 12,3 s / **0,1 s** |
| 4 (~5 700) | 13 s | **5 s** | 32,5 s | 13,7 s / 6,1 s |
| 8 (~7 600–9 400) | **15 s** (15–21) | **18 s** (18–19) | 93,1 s | 16,1 s / 19,6 s |

### Co to znaczy

- **Wersja nie zmienia starego polecenia.** `VACUUM FULL` w 19 jest o ~6% szybszy (13,7 wobec 14,6 s), ale blokuje tak samo:
  `ACCESS EXCLUSIVE` od pierwszej do ostatniej sekundy. Różnica w R to efekt **nowego polecenia**, nie nowej wersji.
- **REPACK (CONCURRENTLY) blokuje na końcu, nie na początku.** Według dokumentacji większość pracy idzie pod
  `SHARE UPDATE EXCLUSIVE`, a `ACCESS EXCLUSIVE` tylko w fazie zamiany. PG19 sam to zalogował (`log_lock_waits` domyślnie on):
  `acquired RowExclusiveLock … after 5818 ms` (6231 i 6795 ms w seriach 2–3).
- **Koniec rośnie z ruchem: 0 → 5 → 18 s.** Pod blokadą REPACK nanosi zmiany przechwycone dekodowaniem logicznym; im więcej
  zapisów w trakcie, tym dłużej. Dokumentacja 19 mówi to samo: *„the lock is typically held for a short time, depending on
  the amount of changes accumulated while the lock was being waited for”* — pomiar podaje, ile to „krótko” znaczy w sekundach.
- **Przewaga REPACK topnieje i przy 8 sesjach znika:** mediana 18 s wobec 15 s. Zastrzeżenie: przy 8 sesjach 4 vCPU są zajęte
  w całości (część wydłużenia to walka o CPU), a ruch przed operacją różnił się między seriami (VF 7 500–8 700 tps, REPACK
  ~9 400 tps). Bezpieczne sformułowanie: „porównywalnie albo gorzej”.
- **„Strata pracy” przy 4 sesjach podobna, rozłożona inaczej.** Szacunek z median (tps przed × czas − tps w trakcie × czas):
  VF ≈ **72 tys.** transakcji mniej, REPACK ≈ **78 tys.** Zysk REPACK-a to **krótsze najdłuższe czekanie** (6 s zamiast 14 s —
  różnica między timeoutem aplikacji a jego brakiem) i to, że przez 80% czasu tabela normalnie przyjmuje zapisy.
- **Rozmiar:** oba warianty odzyskały połowę (2404 → ~1211 MB); REPACK zostawia ~7 MB więcej (wersje wierszy z czasu kopii).
- **MVCC:** REPACK (CONCURRENTLY) nie jest MVCC-safe, `VACUUM FULL` jest (dokumentacja, sekcja 13.6, wymienia tylko `TRUNCATE`,
  przepisujące `ALTER TABLE` i REPACK CONCURRENTLY).

### Co z tym zrobić

- Uruchamiaj poza szczytem: przy małym ruchu REPACK (CONCURRENTLY) naprawdę nie zatrzymuje zapisów.
- Daj aplikacji zapas na kilka sekund czekania (`lock_timeout`, `statement_timeout`) — faza końcowa blokuje też odczyty tabeli.
- Zmierz koniec u siebie: w PG19 `log_lock_waits` jest domyślnie włączone, w logu widać `acquired … after N ms`.

## 🔗 Test F — klucz obcy przy masowym INSERT

`INSERT … SELECT` 5 mln wierszy do `zamowienie` (bez indeksów) z FK do `klient` (100 tys. wierszy, PK) i bez FK.
`jit = off` w obu wersjach. 5 serii, kolejność wersji i wariantów zmienna.

| PG | Z FK | Bez FK | Koszt FK (różnica) | Czas triggerów RI (EXPLAIN) | Wywołań triggerów |
|---|---|---|---|---|---|
| 18 | **27,6 s** (27,2–29,2) | 5,0 s | **22,6 s** | 22,3 s | 5 000 000 |
| 19 | **14,4 s** (14,2–14,5) | 4,9 s | **9,6 s** | 9,4 s | 5 000 000 |
| 18 / 19 | **1,92×** | 1,04× | **2,36×** | 2,37× | — |

- **Ogłoszenie mówi prawdę dla tego scenariusza:** cały INSERT 1,92× szybciej; samo „sprawdź, czy klient istnieje” 2,36×
  (z ~4,5 µs na wiersz do ~1,9 µs).
- **Mechanizm wciąż jest triggerem na wiersz** — 5 mln wywołań w obu wersjach; w 19 każde jest tańsze.
- **Bez FK wersje są prawie równe** (5,0 i 4,9 s) — przyspieszenie dotyczy kluczy obcych, nie wstawiania w ogóle.
- **W prawdziwej tabeli zysk będzie mniejszy:** tu tabela podrzędna nie ma indeksów, a nadrzędna mieści się w pamięci.
  Indeksy, WAL z replikacją i triggery aplikacji dokładają koszt, którego 19 nie przyspiesza.

## ⬆️ Test U — pg_upgrade --check

- Klaster pomocniczy 19: UTF8, libc `en_US.UTF-8`, checksumy on (jak 18). `--check` przy działającym PG18, porty 5432/5434.
- **copy i link: `*Clusters are compatible*`**, wszystkie kontrole `ok` (w tym nowe: `gist_inet_ops/gist_cidr_ops`,
  `objects affected by Unicode update`, `not-null constraint inconsistencies`) → `../results/upgrade_check_*_full/check_*.txt`.
- **Czego to nie mówi:** klaster ma tylko bazy `postgres` (tabela `fakty`) i `labtest`, bez rozszerzeń i niestandardowych typów.
  Klaster z `btree_gist`, `pg_trgm`, `postgis` czy hasłami MD5 to inna historia — `pg_upgrade --check` zawsze na kopii produkcji.

## ⚖️ Warunki i ograniczenia

- Jedna VM (4 vCPU, 3,6 GB RAM, wirtualny NVMe na dysku laptopa). Liczby bezwzględne dotyczą tej maszyny; przenośne są
  **proporcje i kształt** (gdzie stoją zapisy).
- Różnią się tylko wersje i ich domyślne ustawienia ([RUN_PL §3](RUN_PL.md#3-karta-środowiska)); `jit` wyrównany w F.
- Rozrzut serii: R ≤ 5% czasu operacji (część 1), F ≤ 7%.
- Obciążenie zapisem w R to syntetyczny `UPDATE` jednego wiersza po PK; aplikacja z dłuższymi transakcjami czekałaby inaczej,
  szczególnie na fazę końcową REPACK.
