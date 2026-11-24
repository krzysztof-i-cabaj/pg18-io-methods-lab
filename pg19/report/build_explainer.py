# ==============================================================================
# Tytul:        build_explainer.py
# Opis:         Buduje strone docs\REPACK_wyjasnienie.html z szablonu report\explainer_template.html:
#               mediany (czas operacji, sekundy z 0 tps, najdluzsze czekanie, tps) dla PG19
#               VACUUM FULL i REPACK (CONCURRENTLY) przy 1/4/8 sesjach oraz osie czasu tps
#               (seria 1) z plikow results\repack_<ts>\timeline_*.csv. Wstawia JSON w /*__DATA__*/.
# Description [EN]: Builds docs\REPACK_wyjasnienie.html from the template: medians and
#               per-second tps timelines for PG19 VACUUM FULL / REPACK (CONCURRENTLY) at 1/4/8
#               sessions, from the result CSVs; injects JSON into /*__DATA__*/.
#
# Autor:        KCB Kris
# Data:         2026-11-24
# Wersja:       1.1 (--template: wersja EN z report\explainer_template_en.html)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - Python 3.8+, wyniki po .\lab.ps1 fetch (trzy pomiary: czesc 1, czesc 2, kontrola)
# Requirements [EN]: - Python 3.8+, results after .\lab.ps1 fetch (part 1, part 2, control)
#
# Uzycie [PL]:       & "C:\Program Files\Python312\python.exe" report\build_explainer.py
#                      --part1 20261123_183133_full --part2 20261123_192156_full --control 20261123_194837_full
#                      [--template report\explainer_template_en.html] [--out <plik.html>]
# Usage [EN]:        same; --template picks the EN page, --out the output file
# ==============================================================================
import argparse
import csv
import json
import statistics
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "results"
KEY = {"vacuum_full": "vf", "repack_concurrently": "rc"}


def rows(ts):
    p = RES / f"repack_{ts}.csv"
    out = list(csv.DictReader(p.open(encoding="utf-8")))
    for r in out:
        r["clients"] = int(r.get("clients") or 4)       # czesc 1: zawsze 4 sesje
    return [r for r in out if r["ok"] == "1"]


def median_of(rs):
    m = lambda k: statistics.median(float(r[k]) for r in rs)
    return {"op_ms": m("maint_ms"), "zero_s": m("zero_tps_s"), "maxwait_ms": m("max_lat_ms"),
            "tps_before": m("base_tps"), "tps_maint": m("maint_tps"), "n": len(rs)}


def timeline(ts, name):
    p = RES / f"repack_{ts}" / name
    return [[int(r["t_s"]), int(r["tps"]), r["phase"]] for r in csv.DictReader(p.open(encoding="utf-8"))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--part1", required=True)
    ap.add_argument("--part2", required=True)
    ap.add_argument("--control", required=True)
    ap.add_argument("--out", default=str(ROOT / "docs" / "REPACK_wyjasnienie.html"))
    # szablon PL (domyslny) albo EN: report/explainer_template_en.html / PL template (default) or the EN one
    ap.add_argument("--template", default=str(ROOT / "report" / "explainer_template.html"))
    a = ap.parse_args()

    p1, p2, ctl = rows(a.part1), rows(a.part2), rows(a.control)
    pick = {
        ("vf", 1): [r for r in ctl if r["variant"] == "vacuum_full" and r["clients"] == 1],
        ("vf", 4): [r for r in p1 if r["pg"] == "19" and r["variant"] == "vacuum_full"],
        ("vf", 8): [r for r in ctl if r["variant"] == "vacuum_full" and r["clients"] == 8],
        ("rc", 1): [r for r in p2 if r["clients"] == 1],
        ("rc", 4): [r for r in p2 if r["clients"] == 4],
        ("rc", 8): [r for r in p2 if r["clients"] == 8],
    }
    medians = []
    for (k, c), rs in pick.items():
        if not rs:
            raise SystemExit(f"brak serii ok=1 dla {k} c={c}")
        medians.append({"variant": k, "clients": c, **median_of(rs)})
    pg18 = median_of([r for r in p1 if r["pg"] == "18" and r["variant"] == "vacuum_full"])

    tl = {
        "vf": {1: timeline(a.control, "timeline_19_vacuum_full_c1_1.csv"),
               4: timeline(a.part1, "timeline_19_vacuum_full_1.csv"),
               8: timeline(a.control, "timeline_19_vacuum_full_c8_1.csv")},
        "rc": {c: timeline(a.part2, f"timeline_19_repack_concurrently_c{c}_1.csv") for c in (1, 4, 8)},
    }
    data = {"medians": medians, "timelines": tl, "pg18": pg18,
            "nseries": " / ".join(f"{k} c{c}: {len(v)}" for (k, c), v in pick.items()),
            "sources": {"part1": a.part1, "part2": a.part2, "control": a.control}}

    tpl = Path(a.template).read_text(encoding="utf-8")
    if "/*__DATA__*/null" not in tpl:
        raise SystemExit("brak znacznika /*__DATA__*/null w szablonie")
    html = tpl.replace("/*__DATA__*/null", json.dumps(data, ensure_ascii=False, separators=(",", ":")))
    Path(a.out).write_bytes(html.encode("utf-8"))
    for m in medians:
        print(f"{m['variant']} c{m['clients']}: op {m['op_ms']/1000:.1f} s, 0 tps {m['zero_s']:.0f} s, "
              f"max {m['maxwait_ms']/1000:.1f} s, tps przed {m['tps_before']:.0f} (n={m['n']})")
    print(f"zapisano {a.out}")


if __name__ == "__main__":
    main()
