# ==============================================================================
# Tytul:        timeline_stats.py
# Opis:         Analiza osi czasu testu R (results\repack_<ts>\timeline_*.csv): gdzie w czasie
#               operacji wypadaja sekundy z 0 tps (poczatek / srodek / koniec), sredni tps
#               przed, w pierwszej i drugiej polowie operacji oraz po niej.
# Description [EN]: Test R timeline analysis: where the zero-tps seconds fall within the
#               operation, mean tps before, in each half of the operation and after it.
#
# Autor:        KCB Kris
# Data:         2026-11-23
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - Python 3.8+, wyniki po .\lab.ps1 fetch
# Requirements [EN]: - Python 3.8+, results after .\lab.ps1 fetch
#
# Uzycie [PL]:       & "C:\Program Files\Python312\python.exe" report\timeline_stats.py 20261123_183133_full
# Usage [EN]:        same
# ==============================================================================
import csv
import sys
from pathlib import Path

RESULTS = Path(__file__).resolve().parent.parent / "results"


def mean(v):
    return sum(v) / len(v) if v else 0.0


def main():
    ts = sys.argv[1]
    sys.stdout.reconfigure(encoding="utf-8")
    print("| plik | sekund operacji | 0 tps w sekundach operacji | tps przed | tps 1. połowa | tps 2. połowa (bez zer) | tps po |")
    print("|---|---|---|---|---|---|---|")
    for f in sorted((RESULTS / f"repack_{ts}").glob("timeline_*.csv")):
        rows = list(csv.DictReader(f.open(encoding="utf-8")))
        m = [r for r in rows if r["phase"] == "maint"]
        before = [int(r["tps"]) for r in rows if r["phase"] == "before"][2:]   # bez rozgrzewki polaczen
        after = [int(r["tps"]) for r in rows if r["phase"] == "after"][1:]     # bez sekundy zalegosci
        zeros = [int(r["t_s"]) for r in m if int(r["tps"]) == 0]
        half = len(m) // 2
        first = [int(r["tps"]) for r in m[:half]]
        second = [int(r["tps"]) for r in m[half:] if int(r["tps"]) > 0]
        zr = f"{zeros[0]}…{zeros[-1]}" if zeros else "—"
        print(f"| {f.stem.replace('timeline_', '')} | {len(m)} | {zr} | {mean(before):.0f} | "
              f"{mean(first):.0f} | {mean(second):.0f} | {mean(after):.0f} |")


if __name__ == "__main__":
    main()
