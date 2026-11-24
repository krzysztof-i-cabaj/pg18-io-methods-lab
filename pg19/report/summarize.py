# ==============================================================================
# Tytul:        summarize.py
# Opis:         Podsumowanie wynikow testow R i F z CSV (results\repack_<ts>.csv,
#               results\fk_<ts>.csv): mediana / min / max na wersje i wariant, wiersze
#               z ok=0 odrzucone i policzone. Wynik: Markdown na stdout (albo --out plik).
# Description [EN]: Summary of tests R and F from the CSVs: median / min / max per version
#               and variant, rows with ok=0 rejected and counted. Markdown to stdout
#               (or --out file).
#
# Autor:        KCB Kris
# Data:         2026-11-23
# Wersja:       1.1  (R grupowane tez po liczbie sesji clients)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - Python 3.8+ (tylko biblioteka standardowa), wyniki po .\lab.ps1 fetch
# Requirements [EN]: - Python 3.8+ (stdlib only), results after .\lab.ps1 fetch
#
# Uzycie [PL]:       & "C:\Program Files\Python312\python.exe" report\summarize.py --ts 20261124_101500_full
#                    (bez --ts: najnowszy pomiar w results\)
# Usage [EN]:        same (without --ts: the newest run in results\)
# ==============================================================================
import argparse
import csv
import statistics
import sys
from pathlib import Path

RESULTS = Path(__file__).resolve().parent.parent / "results"


def load(path: Path):
    if not path.exists():
        return [], 0
    rows = list(csv.DictReader(path.open(encoding="utf-8")))
    good = [r for r in rows if r.get("ok") == "1"]
    return good, len(rows) - len(good)


def stats(values):
    v = [float(x) for x in values if x not in ("", None)]
    if not v:
        return "—"
    return f"{statistics.median(v):,.0f} ({min(v):,.0f}–{max(v):,.0f})".replace(",", " ")


def group(rows, keys):
    out = {}
    for r in rows:
        out.setdefault(tuple(r[k] for k in keys), []).append(r)
    return out


def latest_ts():
    files = sorted(RESULTS.glob("repack_*.csv")) + sorted(RESULTS.glob("fk_*.csv"))
    if not files:
        sys.exit(f"brak wynikow w {RESULTS}")
    newest = max(files, key=lambda p: p.stat().st_mtime)
    return newest.stem.split("_", 1)[1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ts", help="znacznik pomiaru, np. 20261124_101500_full")
    ap.add_argument("--out", help="plik Markdown (domyslnie stdout)")
    a = ap.parse_args()
    ts = a.ts or latest_ts()
    lines = [f"# 📊 Wyniki PG18 vs PG19 — pomiar `{ts}`", "",
             "Mediana (min–max) z serii z `ok=1`.", ""]

    rep, rep_bad = load(RESULTS / f"repack_{ts}.csv")
    if rep or rep_bad:
        lines += ["## 🧹 R — VACUUM FULL vs REPACK (CONCURRENTLY)", "",
                  "| PG | wariant | sesji | serii | czas operacji ms | tps przed | tps w trakcie | sekund z 0 tps | maks. opóźnienie ms | tabela MB przed → po |",
                  "|---|---|---|---|---|---|---|---|---|---|"]
        for r in rep:
            r.setdefault("clients", "4")          # pomiary sprzed wersji 1.2 skryptu: zawsze 4 sesje
            r["clients"] = r["clients"] or "4"
        keyf = lambda kv: (kv[0][0], kv[0][1], int(kv[0][2]))
        for (pg, var, cl), g in sorted(group(rep, ["pg", "variant", "clients"]).items(), key=keyf):
            size = f'{stats(r["tbl_before_mb"] for r in g)} → {stats(r["tbl_after_mb"] for r in g)}'
            lines.append(f"| {pg} | {var} | {cl} | {len(g)} | {stats(r['maint_ms'] for r in g)} | "
                         f"{stats(r['base_tps'] for r in g)} | {stats(r['maint_tps'] for r in g)} | "
                         f"{stats(r['zero_tps_s'] for r in g)} | {stats(r['max_lat_ms'] for r in g)} | {size} |")
        lines += ["", f"Odrzucone serie (ok=0): {rep_bad}", ""]

    fk, fk_bad = load(RESULTS / f"fk_{ts}.csv")
    if fk or fk_bad:
        lines += ["## 🔗 F — klucz obcy przy masowym INSERT", "",
                  "| PG | wariant | serii | wykonanie ms | zegar ms | triggery ms | wywołań triggerów |",
                  "|---|---|---|---|---|---|---|"]
        g_fk = group(fk, ["pg", "variant"])
        for (pg, var), g in sorted(g_fk.items()):
            lines.append(f"| {pg} | {var} | {len(g)} | {stats(r['exec_ms'] for r in g)} | "
                         f"{stats(r['wall_ms'] for r in g)} | {stats(r['trig_ms'] for r in g)} | "
                         f"{stats(r['trig_calls'] for r in g)} |")
        med = {k: statistics.median(float(r["exec_ms"]) for r in g) for k, g in g_fk.items()}
        if all(k in med for k in [("18", "fk"), ("19", "fk"), ("18", "nofk"), ("19", "nofk")]):
            cost18 = med[("18", "fk")] - med[("18", "nofk")]
            cost19 = med[("19", "fk")] - med[("19", "nofk")]
            lines += ["",
                      f"- INSERT z FK: PG18 / PG19 = **{med[('18', 'fk')] / med[('19', 'fk')]:.2f}x** (ogłoszenie: „nearly 2x”)",
                      f"- sam koszt FK (fk − nofk): PG18 {cost18:,.0f} ms, PG19 {cost19:,.0f} ms".replace(",", " ")
                      + (f" → **{cost18 / cost19:.2f}x**" if cost19 > 0 else "")]
        lines += ["", f"Odrzucone serie (ok=0): {fk_bad}", ""]

    up = RESULTS / f"upgrade_check_{ts}"
    if up.exists():
        lines += ["## ⬆️ U — pg_upgrade --check", ""]
        for mode in ("copy", "link"):
            f = up / f"check_{mode}.txt"
            if f.exists():
                tail = [l for l in f.read_text(encoding="utf-8", errors="replace").splitlines() if l.strip()][-3:]
                lines += [f"- `{mode}`: " + " / ".join(t.strip() for t in tail)]
        lines.append("")

    text = "\n".join(lines)
    if a.out:
        Path(a.out).write_bytes(text.encode("utf-8"))
        print(f"zapisano {a.out}")
    else:
        sys.stdout.reconfigure(encoding="utf-8")
        print(text)


if __name__ == "__main__":
    main()
