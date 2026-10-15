# 🐘 pg18-io-methods-lab — asynchroniczne I/O w PostgreSQL 18: sync vs worker vs io_uring

[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-18.6-336791?logo=postgresql&logoColor=white)]()
[![OS](https://img.shields.io/badge/Rocky_Linux-9.8-orange)]()
[![Metoda](https://img.shields.io/badge/Kontrola_planu-każdy_pomiar-success)]()
[![Ścieżki](https://img.shields.io/badge/Instalacja-skryptowa_%7C_ręczna-blueviolet)]()
[![Licencja](https://img.shields.io/badge/Licencja-MIT-F1C40F)](LICENSE)

> 🎯 Jedna VM, jedna tabela 13 GB, te same zapytania — zmienia się tylko `io_method`. Każdy pomiar sprawdza plan wykonania,
> więc wynik trafia do raportu tylko dla planu, od którego test bierze nazwę. 🇬🇧 [English version](README.md)

**Raport interaktywny:** <https://krzysztof-i-cabaj.github.io/pg18-io-methods-lab/index_pl.html> · Markdown: [docs/RESULTS_PL.md](docs/RESULTS_PL.md)

## 📊 Wyniki

Zimny cache, mediana z 7 przeplatanych serii (główny pomiar, dysk danych na emulowanym kontrolerze SATA) i z 3 serii
(test kontrolny, ten sam dysk przeniesiony na emulowany kontroler NVMe). Mniej = szybciej; ilorazy względem `sync`.

| Test | `sync` | `worker` | `io_uring` | Test kontrolny na NVMe: `sync` / `worker` / `io_uring` |
|---|---:|---:|---:|---:|
| T1a · Seq Scan | 59,1 s | 58,4 s (≈ sync) | **54,2 s** (1,09× szybciej) | — |
| T1b · Parallel Seq Scan | 41,8 s | 57,8 s (1,38× wolniej) | **34,5 s** (1,21× szybciej) | **43,5 s** / 58,4 s / 66,0 s |
| T2 · Bitmap Heap Scan | **11,0 s** | 22,5 s (2,05× wolniej) | 16,8 s (1,53× wolniej) | **5,9 s** / 15,3 s / 11,7 s |
| T3 · Index Scan | 3,34 s | 3,51 s | 3,35 s | — |
| T4 · VACUUM | **15,2 s** | 21,4 s (1,41× wolniej) | 18,2 s (1,20× wolniej) | **10,8 s** / 16,7 s / 14,2 s |

- **`sync` był najszybszy przy Bitmap Heap Scan i VACUUM na obu kontrolerach dysku.**
- **Zysk io_uring przy pełnych skanach zależał od kontrolera:** skan równoległy 1,21× szybciej na SATA, 1,52× wolniej na NVMe.
- **`worker` (domyślny w PostgreSQL 18) przy zimnych danych nigdy nie był szybszy od `sync`** przy domyślnym `io_workers = 3`.
- Index Scan nie używa asynchronicznego I/O w PostgreSQL 18; różnice przy ciepłym cache mieszczą się w szumie.

![Przegląd](docs/charts/overview_pl.svg)
![Test kontrolny](docs/charts/control_nvme_pl.svg)

Wszystkie liczby, wykresy i surowe CSV: [docs/RESULTS_PL.md](docs/RESULTS_PL.md) · [raport interaktywny](https://krzysztof-i-cabaj.github.io/pg18-io-methods-lab/index_pl.html).

## 🎯 Cel

Zmierzyć, co asynchroniczne I/O w PostgreSQL 18 (`io_method = worker` i `io_uring`) zmienia w porównaniu z odczytem
synchronicznym (`sync`) dla ścieżek dostępu, z którymi DBA ma do czynienia na co dzień — pełny skan, skan równoległy,
Bitmap Heap Scan, Index Scan i VACUUM — przy zimnym i ciepłym cache, zmieniając **tylko jedną zmienną**.

## 🧭 Zakres

| W zakresie | Poza zakresem |
|---|---|
| Jedna VM budowana od zera (kickstart albo instalacja ręczna), PostgreSQL 18 z PGDG | Serwery fizyczne, dyski chmurowe i sieciowe |
| Deterministyczne dane testowe (100 mln wierszy), kontrola planów, serie przeplatane, generator raportu | Porównanie wersji PostgreSQL (16/17 vs 18) |
| `io_method` ∈ {`sync`, `worker`, `io_uring`} z domyślnymi `io_workers` / `effective_io_concurrency` | Strojenie `io_workers`, `effective_io_concurrency`, `io_combine_limit` |

## 🧪 Co jest mierzone

| Test | Zapytanie / operacja | Węzeł planu (sprawdzany przy każdym pomiarze) | Cache |
|---|---|---|---|
| T1a | `count(*), avg(v)` z całej tabeli, bez równoległości | `Seq Scan` | zimny |
| T1b | to samo z równoległymi workerami | `Parallel Seq Scan` | zimny |
| T2 | jeden dzień danych (~54 tys. wierszy rozrzuconych po tabeli) | `Bitmap Heap Scan` | zimny, ciepły |
| T3 | 5000 wierszy w kolejności indeksu po losowym kluczu | `Index Scan` | zimny, ciepły |
| T4 | `VACUUM` kopii 10 mln wierszy po usunięciu 10% | — (ta sama praca sprawdzona: 1 000 000 usuniętych krotek) | zimny |

Zimny cache = zatrzymanie PostgreSQL, wyczyszczenie cache stron systemu i start PostgreSQL przed **każdym** pomiarem.
7 serii, tryby przeplatane (`sync → worker → io_uring` → …). Szczegóły: [docs/METHODOLOGY_PL.md](docs/METHODOLOGY_PL.md).

## 📁 Struktura

```text
.
├── lab.ps1, lab.config.psd1      # ścieżka skryptowa: jedno polecenie na etap (plan, build, provision, …)
├── host/                         # moduły PowerShell dla VirtualBox + serwer HTTP kickstartu
├── kickstart/pgio.ks.tmpl        # instalacja Rocky Linux bez obsługi (szablon, bez sekretów)
├── guest/                        # provision.sh (PostgreSQL 18), env_card.sh (karta środowiska)
├── sql/01_create_test_data.sql   # tabela testowa 100 mln wierszy
├── bench/                        # tests.conf, plan_check.sh, run_bench.sh
├── report/make_report.py         # CSV → RESULTS.md, wykresy SVG, GitHub Pages
├── results/                      # surowe CSV, plany JSON, logi, karta środowiska; control_nvme/ = test kontrolny
└── docs/                         # INSTALL, METHODOLOGY, RESULTS (EN + PL), strona GitHub Pages
```

## 📋 Wymagania

Windows 11 + PowerShell 7 (ścieżka skryptowa) albo dowolny host z VirtualBox (ścieżka ręczna) · VirtualBox 7.x · Python 3.8+ ·
para kluczy OpenSSH · `Rocky-9.8-x86_64-minimal.iso` · ~80 GB wolnego miejsca · sieć host-only `192.168.56.0/24`.

## 🏗️ Jak powstaje VM — Kickstart po HTTP

Bez klikania w instalatorze. Jedno polecenie, `.\lab.ps1 build`, prowadzi od pustego hosta do działającej VM z Rocky Linux w ~10–20 minut:

```text
lab.ps1 build
  ├─ uruchamia mały serwer HTTP na hoście (192.168.56.1:8000), udostępnia tylko kickstart/
  ├─ VBoxManage: tworzy VM, dyski, karty sieciowe, podpina ISO, startuje
  ├─ VBoxManage keyboardputscancode: wpisuje w menu startowym
  │     inst.ks=http://192.168.56.1:8000/kickstart/pgio.ks  ip=192.168.56.40:…
  ├─ instalator pobiera kickstart i instaluje system bez obsługi
  │     (układ dysków, sieć, pakiety, klucz SSH, ustawienia jądra w %post)
  └─ host czeka na SSH, odłącza ISO, zatrzymuje serwer HTTP
```

Kickstart jest szablonem (`kickstart/pgio.ks.tmpl`): IP, nazwa hosta i klucz SSH są wstawiane dla każdej maszyny, więc ten sam
przepływ buduje lab z **4–5 i więcej VM** bez dodatkowej pracy ręcznej — każda identyczna, odbudowywana od zera w kilka minut,
gdy test potrzebuje czystego startu. Odpowiednik ręczny (samodzielne wpisanie `inst.ks=` albo instalator interaktywny):
[INSTALL_PL §3](docs/INSTALL_PL.md).

## 🚀 Uruchomienie

Każdy etap ma dwie ścieżki: 🤖 **skryptową (automatycznie / półautomatycznie)** i ✋ **ręczną** (zwykłe `VBoxManage`, instalator, `dnf`, `psql`).
Pełna instrukcja obu: [docs/INSTALL_PL.md](docs/INSTALL_PL.md).

| # | Etap | 🤖 Ścieżka skryptowa | ✋ Ścieżka ręczna |
|---|---|---|---|
| 1 | Kontrola hosta | `.\lab.ps1 plan` | [INSTALL_PL §2](docs/INSTALL_PL.md#️-2-konfiguracja-hosta) |
| 2 | VM + Rocky Linux 9.8 | `.\lab.ps1 build` | [INSTALL_PL §3](docs/INSTALL_PL.md#️-3-budowa-vm) |
| 3 | PostgreSQL 18 | `.\lab.ps1 provision -DryRun`, potem `provision` | [INSTALL_PL §4](docs/INSTALL_PL.md#-4-instalacja-postgresql-18) |
| 4 | Karta środowiska | `.\lab.ps1 envcard` | [INSTALL_PL §5](docs/INSTALL_PL.md#-5-karta-środowiska) |
| 5 | Dane testowe (~15 min) | `.\lab.ps1 loaddata` | [INSTALL_PL §6](docs/INSTALL_PL.md#-6-dane-testowe) |
| 6 | Kontrola planów | `.\lab.ps1 plans` | [INSTALL_PL §7](docs/INSTALL_PL.md#-7-kontrola-planów-tylko-explain) |
| 7 | Pomiary (~85 min) | `.\lab.ps1 bench 7`, potem `fetch` | [INSTALL_PL §8](docs/INSTALL_PL.md#️-8-pomiary) |
| 8 | Raport | `python report\make_report.py` | [INSTALL_PL §9](docs/INSTALL_PL.md#-9-raport) |

## ✅ Weryfikacja

- `.\lab.ps1 plans` → **PASS** dla T1a, T1b, T2, T3 przed pomiarem.
- `results/raw_*.csv` → każdy wiersz `plan_ok = 1`; wiersze VACUUM pokazują tę samą pracę w każdym trybie.
- `python report\make_report.py --dry-run` → mediany na ekranie, `rejected = 0`.

## ↩️ Wycofanie

`.\lab.ps1 destroy pgio` (albo `VBoxManage unregistervm pgio --delete`) usuwa VM razem z dyskami.
Adapter host-only, ISO i reguła zapory zostają; regułę usuniesz poleceniem `Remove-NetFirewallRule -DisplayName 'pgio-lab-ks-8000'`.

## ⚠️ Uwagi i ograniczenia

- **Te liczby opisują jedno środowisko:** VM w VirtualBox (4 vCPU, 3,6 GB RAM) na laptopie z Samsung 990 PRO NVMe,
  cache I/O hosta wyłączony. Test kontrolny pokazuje, że sama emulowana warstwa dyskowa potrafi odwrócić wynik — sprawdzaj na własnym sprzęcie.
- Tylko wartości domyślne PostgreSQL 18 (`io_workers = 3`, `effective_io_concurrency = 16`, `io_combine_limit = 128kB`); ich strojenie to kolejny krok.
- RHEL/Rocky 9 wyłączają io_uring w jądrze (`kernel.io_uring_disabled = 2`); lab ustawia `0`. Bez tego `io_method = io_uring` nie wystartuje.
- W czasie pomiarów nie może działać żadna inna VM (wspólny dysk hosta); `lab.ps1 plan` to sprawdza.
- Dysk danych ma **stały rozmiar**, a cache I/O hosta jest **wyłączony** — inaczej „zimny cache” w gościu byłby obsługiwany z RAM hosta.

## 🔐 Bezpieczeństwo

Nigdzie nie ma haseł: root jest zablokowany w kickstarcie, dostęp tylko Twoim kluczem publicznym SSH, PostgreSQL słucha na `localhost`.
Wyrenderowany `kickstart/pgio.ks` (zawiera Twój klucz publiczny) jest w `.gitignore`; w repozytorium jest tylko szablon.

## 👤 Autor

Krzysztof Cabaj · KCB Consulting · Licencja: [MIT](LICENSE)
