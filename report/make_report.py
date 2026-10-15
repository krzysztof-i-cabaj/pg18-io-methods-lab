#!/usr/bin/env python3
# ==============================================================================
# Tytul:        make_report.py
# Opis:         Generator raportu z surowych pomiarow (results/raw_<ts>.csv):
#               mediany, min/max/p90 per test x cache x io_method, czas wzgledem sync,
#               wykresy SVG (jasny/ciemny motyw), docs/RESULTS.md + RESULTS_PL.md,
#               strona GitHub Pages docs/index.html + docs/index_pl.html.
#               Pomiary z plan_ok != 1 sa odrzucane i liczone w raporcie.
# Description [EN]: Report generator for raw measurements: medians, min/max/p90 per
#               test x cache x io_method, time relative to sync, SVG charts (light/dark),
#               docs/RESULTS*.md and the GitHub Pages site docs/index*.html.
#               Rows with plan_ok != 1 are rejected and counted.
#
# Autor:        KCB Kris
# Data:         2026-10-15
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - Python 3.9+ (tylko biblioteka standardowa)
# Requirements [EN]: - Python 3.9+ (standard library only)
#
# Uzycie [PL]:       python report/make_report.py                     (najnowszy results/raw_*.csv)
#                    python report/make_report.py --csv results/raw_X.csv --dry-run
# Usage [EN]:        same; --dry-run prints the summary without writing files
# ==============================================================================
import argparse
import csv
import html
import math
import re
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPO_URL = "https://github.com/krzysztof-i-cabaj/pg18-io-methods-lab"
MODES = ["sync", "worker", "io_uring"]

# Kolejnosc paneli / panel order: (test, cache)
PANELS = [("T1a", "cold"), ("T1b", "cold"), ("T2", "cold"), ("T3", "cold"),
          ("T4", "cold"), ("T2", "warm"), ("T3", "warm")]

TXT = {
    "en": {
        "T1a": "T1a · Seq Scan, 1 process",
        "T1b": "T1b · Parallel Seq Scan, 2 workers",
        "T2": "T2 · Bitmap Heap Scan, 1 day (~54k rows)",
        "T3": "T3 · Index Scan, 5,000 rows",
        "T4": "T4 · VACUUM, 10M rows, 10% deleted",
        "cold": "cold cache", "warm": "warm cache",
        "faster": "faster", "slower": "slower", "same": "≈ sync", "baseline": "baseline",
        "median": "median", "range": "min–max", "rel_axis": "cold cache: median time relative to sync (lower = faster)",
        "sync_line": "sync = 1.0",
        "dec": ".", "thou": ",",
    },
    "pl": {
        "T1a": "T1a · Seq Scan, 1 proces",
        "T1b": "T1b · Parallel Seq Scan, 2 workery",
        "T2": "T2 · Bitmap Heap Scan, 1 dzień (~54 tys. wierszy)",
        "T3": "T3 · Index Scan, 5000 wierszy",
        "T4": "T4 · VACUUM, 10 mln wierszy, 10% usuniętych",
        "cold": "zimny cache", "warm": "ciepły cache",
        "faster": "szybciej", "slower": "wolniej", "same": "≈ sync", "baseline": "punkt odniesienia",
        "median": "mediana", "range": "min–max", "rel_axis": "zimny cache: mediana czasu względem sync (mniej = szybciej)",
        "sync_line": "sync = 1,0",
        "dec": ",", "thou": " ",
    },
}

# Paleta zwalidowana (dataviz validate_palette.js, 3 sloty, all-pairs, jasny i ciemny: PASS)
LIGHT = {"surface": "#fcfcfb", "ink": "#0b0b0b", "ink2": "#52514e", "muted": "#898781",
         "grid": "#e1e0d9", "axis": "#c3c2b7",
         "sync": "#2a78d6", "worker": "#eb6834", "io_uring": "#1baf7a"}
DARK = {"surface": "#1a1a19", "ink": "#f0efec", "ink2": "#c3c2b7", "muted": "#898781",
        "grid": "#2c2c2a", "axis": "#383835",
        "sync": "#3987e5", "worker": "#d95926", "io_uring": "#199e70"}


# ------------------------------------------------------------------------------
# Dane / data
# ------------------------------------------------------------------------------
def load(csv_path):
    rows, rejected = [], []
    with open(csv_path, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            if r["plan_ok"] != "1":
                rejected.append(r)
                continue
            ms = float(r["exec_ms"])
            # run_bench.sh 1.0 zapisywal T4 w mikrosekundach; VACUUM > 1000 s jest tu niemozliwy
            # run_bench.sh 1.0 wrote T4 in microseconds; a VACUUM longer than 1000 s is impossible here
            if r["test"] == "T4" and ms > 1_000_000:
                ms /= 1000.0
            rows.append({
                "series": int(r["series"]), "mode": r["io_method"], "test": r["test"],
                "cache": r["cache"], "ms": ms,
                "read": int(r["shared_read"]) if r["shared_read"] else None,
                "io_ms": float(r["io_read_ms"]) if r["io_read_ms"] else None,
                "note": r.get("note", ""),
            })
    return rows, rejected


def pct(values, p):   # percentyl metoda najblizszej rangi / nearest-rank percentile
    s = sorted(values)
    k = max(1, math.ceil(p / 100 * len(s)))
    return s[k - 1]


def summarize(rows):
    out = {}
    for test, cache in PANELS:
        for m in MODES:
            v = [r for r in rows if r["test"] == test and r["cache"] == cache and r["mode"] == m]
            if not v:
                continue
            ms = [r["ms"] for r in v]
            io = [r["io_ms"] for r in v if r["io_ms"] is not None]
            rd = [r["read"] for r in v if r["read"] is not None]
            out[(test, cache, m)] = {
                "n": len(ms), "median": statistics.median(ms), "min": min(ms), "max": max(ms),
                "p90": pct(ms, 90),
                "io_median": statistics.median(io) if io else None,
                "read_median": int(statistics.median(rd)) if rd else None,
                "notes": sorted({r["note"] for r in v if r["note"]}),
            }
        base = out.get((test, cache, "sync"))
        for m in MODES:
            s = out.get((test, cache, m))
            if s and base:
                s["rel"] = s["median"] / base["median"]
    return out


# ------------------------------------------------------------------------------
# Formatowanie / formatting
# ------------------------------------------------------------------------------
def num(x, digits, lang):
    t = TXT[lang]
    s = f"{x:,.{digits}f}"
    return s.replace(",", "\x00").replace(".", t["dec"]).replace("\x00", t["thou"])


def fmt_ms(ms, lang):
    if ms >= 1000:
        return f"{num(ms / 1000, 1 if ms >= 10000 else 2, lang)} s"
    return f"{num(ms, 1 if ms < 100 else 0, lang)} ms"


def fmt_rel(rel, mode, lang):
    t = TXT[lang]
    if mode == "sync":
        return t["baseline"]
    if abs(rel - 1) < 0.03:
        return t["same"]
    if rel < 1:
        return f"{num(1 / rel, 2, lang)}× {t['faster']}"
    return f"{num(rel, 2, lang)}× {t['slower']}"


def nice_ticks(vmax, n=5):
    raw = vmax / n
    mag = 10 ** math.floor(math.log10(raw))
    step = min((s * mag for s in (1, 2, 2.5, 5, 10) if s * mag >= raw), default=10 * mag)
    top = math.ceil(vmax / step) * step
    ticks, v = [], 0.0
    while v <= top + 1e-9:
        ticks.append(v)
        v += step
    return ticks


def e(s):
    return html.escape(str(s), quote=True)


# ------------------------------------------------------------------------------
# SVG
# ------------------------------------------------------------------------------
SVG_CLASSES = """
.bg{fill:var(--surface)} .grid{stroke:var(--grid);stroke-width:1}
.axis{stroke:var(--axis);stroke-width:1} .ref{stroke:var(--ink2);stroke-width:1.5}
.t1{fill:var(--ink)} .t2{fill:var(--ink2)} .tm{fill:var(--muted)}
.wh{stroke:var(--ink);stroke-width:1.5;stroke-linecap:round;opacity:.75}
.m-sync{fill:var(--sync)} .m-worker{fill:var(--worker)} .m-io_uring{fill:var(--io_uring)}
.dot{stroke:var(--surface);stroke-width:2}
.hit{fill:transparent} .hit:hover+.mk,.hit:focus+.mk{opacity:.8}
text{font-family:system-ui,-apple-system,"Segoe UI",sans-serif}
.num{font-variant-numeric:tabular-nums}
"""


def svg_style():
    lv = ";".join(f"--{k}:{v}" for k, v in LIGHT.items())
    dv = ";".join(f"--{k}:{v}" for k, v in DARK.items())
    return (f"<style>svg{{{lv}}}@media (prefers-color-scheme:dark){{svg{{{dv}}}}}"
            f"{SVG_CLASSES}</style>")


def svg_open(w, h, title, standalone):
    head = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}" '
            f'role="img" aria-label="{e(title)}" class="chart">')
    if standalone:
        head += svg_style()
    return head + f'<rect class="bg" x="0" y="0" width="{w}" height="{h}" rx="8"/>'


def bar_path(x0, y, x1, h, r=4):
    w = max(x1 - x0, 0.1)
    r = min(r, w, h / 2)
    return (f"M{x0:.1f},{y:.1f}H{x0 + w - r:.1f}Q{x0 + w:.1f},{y:.1f} {x0 + w:.1f},{y + r:.1f}"
            f"V{y + h - r:.1f}Q{x0 + w:.1f},{y + h:.1f} {x0 + w - r:.1f},{y + h:.1f}H{x0:.1f}Z")


def svg_panel(test, cache, S, lang, standalone):
    """Jeden panel: 3 slupki (mediana) + wasy min-max + etykieta czasu i relacji do sync."""
    t = TXT[lang]
    title = f"{t[test]} — {t[cache]}"
    stats = [(m, S[(test, cache, m)]) for m in MODES if (test, cache, m) in S]
    W, L, R, TOP, ROW, BAR = 760, 92, 210, 46, 40, 22
    H = TOP + ROW * len(stats) + 30
    vmax = max(s["max"] for _, s in stats)
    unit_s = vmax >= 1000
    div = 1000 if unit_s else 1
    ticks = nice_ticks(vmax / div)
    top = ticks[-1]
    pw = W - L - R
    X = lambda v: L + (v / div) / top * pw
    out = [svg_open(W, H, title, standalone)]
    out.append(f'<text class="t1" x="16" y="26" font-size="15" font-weight="600">{e(title)}</text>')
    base_y = TOP + ROW * len(stats)
    for tv in ticks:
        x = L + tv / top * pw
        out.append(f'<line class="grid" x1="{x:.1f}" y1="{TOP - 6}" x2="{x:.1f}" y2="{base_y}"/>')
        lab = num(tv, 0 if tv == int(tv) else 1, lang)
        if tv == ticks[-1]:
            lab += " s" if unit_s else " ms"
        out.append(f'<text class="tm num" x="{x:.1f}" y="{base_y + 18}" font-size="11" text-anchor="middle">{lab}</text>')
    out.append(f'<line class="axis" x1="{L}" y1="{TOP - 6}" x2="{L}" y2="{base_y}"/>')
    for i, (m, s) in enumerate(stats):
        y = TOP + i * ROW + (ROW - BAR) / 2
        cy = y + BAR / 2
        rel = fmt_rel(s.get("rel", 1), m, lang)
        tip = (f"{m} · {t['median']} {fmt_ms(s['median'], lang)} · {t['range']} "
               f"{fmt_ms(s['min'], lang)}–{fmt_ms(s['max'], lang)} · n={s['n']} · {rel}")
        out.append(f'<text class="t2" x="{L - 10}" y="{cy + 4:.1f}" font-size="13" text-anchor="end">{m}</text>')
        out.append(f'<rect class="hit" x="0" y="{TOP + i * ROW}" width="{W}" height="{ROW}" tabindex="0" data-tip="{e(tip)}">'
                   f'<title>{e(tip)}</title></rect>')
        out.append(f'<g class="mk" pointer-events="none"><path class="m-{m}" d="{bar_path(L, y, X(s["median"]), BAR)}"/>')
        x1, x2 = X(s["min"]), X(s["max"])
        out.append(f'<line class="wh" x1="{x1:.1f}" y1="{cy:.1f}" x2="{x2:.1f}" y2="{cy:.1f}"/>'
                   f'<line class="wh" x1="{x1:.1f}" y1="{cy - 5:.1f}" x2="{x1:.1f}" y2="{cy + 5:.1f}"/>'
                   f'<line class="wh" x1="{x2:.1f}" y1="{cy - 5:.1f}" x2="{x2:.1f}" y2="{cy + 5:.1f}"/></g>')
        lx = max(X(s["median"]), x2) + 10
        out.append(f'<text class="t1 num" x="{lx:.1f}" y="{cy + 4:.1f}" font-size="13" font-weight="600">'
                   f'{fmt_ms(s["median"], lang)}<tspan class="t2" font-weight="400"> · {e(rel)}</tspan></text>')
    out.append("</svg>")
    return "\n".join(out)


def svg_overview(S, lang, standalone):
    """Mediana wzgledem sync (sync = 1,0), tylko zimny cache (cieply = ms, w granicach szumu); jedna os."""
    t = TXT[lang]
    panels = [p for p in PANELS if p[1] == "cold"]
    W, L, R, TOP, ROW = 760, 260, 40, 64, 34
    H = TOP + ROW * len(panels) + 40
    rels = [S[(a, b, m)]["rel"] for a, b in panels for m in MODES if (a, b, m) in S]
    top = max(2.0, math.ceil(max(rels) * 4) / 4)
    ticks = [i * 0.5 for i in range(int(top / 0.5) + 1)]
    pw = W - L - R
    X = lambda v: L + v / top * pw
    out = [svg_open(W, H, t["rel_axis"], standalone)]
    out.append(f'<text class="t1" x="16" y="26" font-size="15" font-weight="600">{e(t["rel_axis"])}</text>')
    # legenda / legend
    lx = 16
    out.append(f'<line class="ref" x1="{lx}" y1="44" x2="{lx + 18}" y2="44"/>'
               f'<text class="t2" x="{lx + 24}" y="48" font-size="12">sync</text>')
    lx += 76
    for m in MODES[1:]:
        out.append(f'<circle class="m-{m} dot" cx="{lx + 6}" cy="44" r="6"/>'
                   f'<text class="t2" x="{lx + 18}" y="48" font-size="12">{m}</text>')
        lx += 100
    base_y = TOP + ROW * len(panels)
    for tv in ticks:
        x = X(tv)
        out.append(f'<line class="grid" x1="{x:.1f}" y1="{TOP}" x2="{x:.1f}" y2="{base_y}"/>')
        out.append(f'<text class="tm num" x="{x:.1f}" y="{base_y + 18}" font-size="11" text-anchor="middle">'
                   f'{num(tv, 1, lang)}</text>')
    out.append(f'<line class="ref" x1="{X(1):.1f}" y1="{TOP - 4}" x2="{X(1):.1f}" y2="{base_y}"/>')
    for i, (test, cache) in enumerate(panels):
        cy = TOP + i * ROW + ROW / 2
        out.append(f'<text class="t2" x="{L - 14}" y="{cy + 4:.1f}" font-size="12.5" text-anchor="end">'
                   f'{e(t[test].split(" · ")[0] + " · " + t[test].split(" · ")[1].split(",")[0])}</text>')
        if i:
            out.append(f'<line class="grid" x1="16" y1="{TOP + i * ROW}" x2="{W - 16}" y2="{TOP + i * ROW}" opacity=".6"/>')
        for m in MODES[1:]:
            s = S.get((test, cache, m))
            if not s:
                continue
            tip = (f"{t[test]} · {t[cache]} · {m}: {fmt_ms(s['median'], lang)} · "
                   f"{fmt_rel(s['rel'], m, lang)}")
            x = X(s["rel"])
            out.append(f'<circle class="hit" cx="{x:.1f}" cy="{cy:.1f}" r="13" tabindex="0" data-tip="{e(tip)}">'
                       f'<title>{e(tip)}</title></circle>'
                       f'<circle class="mk m-{m} dot" cx="{x:.1f}" cy="{cy:.1f}" r="6" pointer-events="none"/>')
    out.append("</svg>")
    return "\n".join(out)


# ------------------------------------------------------------------------------
# Test kontrolny: dysk danych na kontrolerze NVMe / control run: data disk on NVMe
# ------------------------------------------------------------------------------
CTESTS = ["T1b", "T2", "T4"]
CT = {
    "en": {
        "h": "Control run: data disk on an NVMe controller",
        "s": "one variable changed: the VM's virtual disk controller (SATA/AHCI → NVMe); 3 series, cold cache",
        "axis": "median time relative to sync, per disk controller (lower = faster)",
        "hdr": ["Test", "io_method", "SATA median", "NVMe median", "SATA vs sync", "NVMe vs sync"],
        "note": "Same VM, data, PostgreSQL settings and queries; only the data disk was moved from the emulated SATA (AHCI) "
                "controller to an emulated NVMe controller (host I/O cache off on both). Source: `{csv}` · {n} measurements · "
                "{rej} rejected.",
    },
    "pl": {
        "h": "Test kontrolny: dysk danych na kontrolerze NVMe",
        "s": "zmieniona jedna zmienna: wirtualny kontroler dysku VM (SATA/AHCI → NVMe); 3 serie, zimny cache",
        "axis": "mediana czasu względem sync, dla każdego kontrolera dysku (mniej = szybciej)",
        "hdr": ["Test", "io_method", "Mediana SATA", "Mediana NVMe", "SATA vs sync", "NVMe vs sync"],
        "note": "Ta sama VM, dane, ustawienia PostgreSQL i zapytania; jedynie dysk danych przeniesiono z emulowanego kontrolera "
                "SATA (AHCI) na emulowany kontroler NVMe (na obu cache I/O hosta wyłączony). Źródło: `{csv}` · {n} pomiarów · "
                "{rej} odrzuconych.",
    },
}


def svg_compare(S, C, lang, standalone):
    """Kropki worker/io_uring wzgledem sync dla SATA i NVMe; jedna os."""
    t = TXT[lang]
    rows = [(test, ctl, D) for test in CTESTS for ctl, D in (("SATA", S), ("NVMe", C))]
    W, L, R, TOP, ROW = 760, 260, 40, 64, 30
    H = TOP + ROW * len(rows) + 40
    rels = [D[(a, "cold", m)]["rel"] for a, _, D in rows for m in MODES if (a, "cold", m) in D]
    top = max(2.0, math.ceil(max(rels) * 4) / 4)
    ticks = [i * 0.5 for i in range(int(top / 0.5) + 1)]
    pw = W - L - R
    X = lambda v: L + v / top * pw
    out = [svg_open(W, H, CT[lang]["axis"], standalone)]
    out.append(f'<text class="t1" x="16" y="26" font-size="15" font-weight="600">{e(CT[lang]["axis"])}</text>')
    lx = 16
    out.append(f'<line class="ref" x1="{lx}" y1="44" x2="{lx + 18}" y2="44"/>'
               f'<text class="t2" x="{lx + 24}" y="48" font-size="12">sync</text>')
    lx += 76
    for m in MODES[1:]:
        out.append(f'<circle class="m-{m} dot" cx="{lx + 6}" cy="44" r="6"/>'
                   f'<text class="t2" x="{lx + 18}" y="48" font-size="12">{m}</text>')
        lx += 100
    base_y = TOP + ROW * len(rows)
    for tv in ticks:
        x = X(tv)
        out.append(f'<line class="grid" x1="{x:.1f}" y1="{TOP}" x2="{x:.1f}" y2="{base_y}"/>')
        out.append(f'<text class="tm num" x="{x:.1f}" y="{base_y + 18}" font-size="11" text-anchor="middle">'
                   f'{num(tv, 1, lang)}</text>')
    out.append(f'<line class="ref" x1="{X(1):.1f}" y1="{TOP - 4}" x2="{X(1):.1f}" y2="{base_y}"/>')
    for i, (test, ctl, D) in enumerate(rows):
        cy = TOP + i * ROW + ROW / 2
        name = t[test].split(" · ")[0] + " · " + t[test].split(" · ")[1].split(",")[0]
        lab = (name + " · " if ctl == "SATA" else "") + ctl
        out.append(f'<text class="{"t2" if ctl == "SATA" else "tm"}" x="{L - 14}" y="{cy + 4:.1f}" font-size="12.5" '
                   f'text-anchor="end">{e(lab)}</text>')
        if i and ctl == "SATA":
            out.append(f'<line class="grid" x1="16" y1="{TOP + i * ROW}" x2="{W - 16}" y2="{TOP + i * ROW}"/>')
        for m in MODES[1:]:
            s = D.get((test, "cold", m))
            if not s:
                continue
            tip = f"{t[test]} · {ctl} · {m}: {fmt_ms(s['median'], lang)} · {fmt_rel(s['rel'], m, lang)}"
            x = X(s["rel"])
            out.append(f'<circle class="hit" cx="{x:.1f}" cy="{cy:.1f}" r="13" tabindex="0" data-tip="{e(tip)}">'
                       f'<title>{e(tip)}</title></circle>'
                       f'<circle class="mk m-{m} dot" cx="{x:.1f}" cy="{cy:.1f}" r="6" pointer-events="none"/>')
    out.append("</svg>")
    return "\n".join(out)


def compare_rows(S, C, lang):
    for test in CTESTS:
        for m in MODES:
            a, b = S.get((test, "cold", m)), C.get((test, "cold", m))
            if a and b:
                yield [test, m, fmt_ms(a["median"], lang), f'{fmt_ms(b["median"], lang)} (n={b["n"]})',
                       fmt_rel(a.get("rel", 1), m, lang), fmt_rel(b.get("rel", 1), m, lang)]


def md_compare(S, C, lang):
    h = CT[lang]["hdr"]
    lines = ["| " + " | ".join(h) + " |", "|---|---|---:|---:|---:|---:|"]
    for r in compare_rows(S, C, lang):
        r[1] = f"`{r[1]}`"
        lines.append("| " + " | ".join(r) + " |")
    return "\n".join(lines)


def html_compare(S, C, lang):
    h = CT[lang]["hdr"]
    out = ['<div class="tablewrap"><table><thead><tr>']
    out += [f'<th{" class=\"r\"" if i >= 2 else ""}>{e(c)}</th>' for i, c in enumerate(h)]
    out.append("</tr></thead><tbody>")
    for r in compare_rows(S, C, lang):
        out.append("<tr>" + "".join(
            f'<td class="{"r num" if i >= 2 else ""}">'
            f'{f"<span class=key style=background:var(--{r[1]})></span>" if i == 1 else ""}{e(c)}</td>'
            for i, c in enumerate(r)) + "</tr>")
    out.append("</tbody></table></div>")
    return "".join(out)


# ------------------------------------------------------------------------------
# Tabele / tables
# ------------------------------------------------------------------------------
HDR = {
    "en": ["Test", "Cache", "io_method", "n", "Median", "Min", "Max", "p90", "vs sync", "I/O read"],
    "pl": ["Test", "Cache", "io_method", "n", "Mediana", "Min", "Max", "p90", "vs sync", "Odczyt I/O"],
}


def table_rows(S, lang):
    t = TXT[lang]
    for test, cache in PANELS:
        for m in MODES:
            s = S.get((test, cache, m))
            if not s:
                continue
            yield [test, t[cache], m, str(s["n"]), fmt_ms(s["median"], lang), fmt_ms(s["min"], lang),
                   fmt_ms(s["max"], lang), fmt_ms(s["p90"], lang), fmt_rel(s.get("rel", 1), m, lang),
                   fmt_ms(s["io_median"], lang) if s["io_median"] is not None else "—"]


def md_table(S, lang):
    h = HDR[lang]
    lines = ["| " + " | ".join(h) + " |", "|" + "|".join(["---"] * 3 + ["---:"] * 7) + "|"]
    for r in table_rows(S, lang):
        r[2] = f"`{r[2]}`"
        lines.append("| " + " | ".join(r) + " |")
    return "\n".join(lines)


def html_table(S, lang):
    h = HDR[lang]
    out = ['<div class="tablewrap"><table><thead><tr>']
    out += [f'<th{" class=\"r\"" if i >= 3 else ""}>{e(c)}</th>' for i, c in enumerate(h)]
    out.append("</tr></thead><tbody>")
    for r in table_rows(S, lang):
        out.append("<tr>" + "".join(
            f'<td class="{"r num" if i >= 3 else ""}">'
            f'{f"<span class=key style=background:var(--{r[2]})></span>" if i == 2 else ""}{e(c)}</td>'
            for i, c in enumerate(r)) + "</tr>")
    out.append("</tbody></table></div>")
    return "".join(out)


# ------------------------------------------------------------------------------
# Tekst wnioskow (opcjonalny, pisany recznie) / findings text (optional, hand-written)
# ------------------------------------------------------------------------------
def read_findings(lang):
    p = ROOT / "report" / f"findings_{lang}.md"
    return p.read_text(encoding="utf-8").strip() if p.exists() else ""


def md_inline(s):
    s = e(s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"`(.+?)`", r"<code>\1</code>", s)
    s = re.sub(r"\[(.+?)\]\((.+?)\)", r'<a href="\2">\1</a>', s)
    return s


def md_to_html(md):   # wystarczy na akapity i listy / paragraphs and bullet lists only
    out, inlist = [], False
    for block in md.split("\n\n"):
        lines = block.strip().splitlines()
        if lines and all(l.startswith("- ") for l in lines):
            out.append("<ul>" + "".join(f"<li>{md_inline(l[2:])}</li>" for l in lines) + "</ul>")
        elif lines:
            out.append(f"<p>{md_inline(' '.join(lines))}</p>")
    return "\n".join(out)


# ------------------------------------------------------------------------------
# Karta srodowiska / environment card
# ------------------------------------------------------------------------------
def env_facts(lang):
    p = ROOT / "results" / "env_card.txt"
    txt = p.read_text(encoding="utf-8") if p.exists() else ""

    def grab(pattern, default="?"):
        m = re.search(pattern, txt, re.M)
        return m.group(1).strip() if m else default

    pl = lang == "pl"
    ram = grab(r"^Mem:\s+(\d+)")
    ram = f"{num(int(ram) / 1024, 1, lang)} GB" if ram.isdigit() else ram
    return [
        ("PostgreSQL", grab(r"^(PostgreSQL [\d.]+)")),
        ("OS", grab(r"^(Rocky Linux release [\d.]+)") + ", kernel " + grab(r"^(\d+\.\d+\.\d+-[\w.]+)")),
        ("CPU", grab(r"Model name:\s+(.+)") + (" · 4 vCPU" if not pl else " · 4 vCPU")),
        ("RAM", ram + " · shared_buffers 1 GB"),
        ("Storage" if not pl else "Dysk", grab(r"Dysk hosta: (.+)") + " · VirtualBox " + grab(r"VirtualBox: ([\d.]+)")
         + (" · host I/O cache off" if not pl else " · cache I/O hosta wyłączony")),
        ("I/O", "effective_io_concurrency " + grab(r"effective_io_concurrency = (\d+)") + " · io_workers "
         + grab(r"io_workers = (\d+)") + " · io_combine_limit 128 kB"),
        ("Data" if not pl else "Dane", "fakty: 100 M rows, 13 GB + 4.9 GB indexes" if not pl
         else "fakty: 100 mln wierszy, 13 GB + 4,9 GB indeksów"),
    ]


# ------------------------------------------------------------------------------
# Kafelki: najszybszy tryb per test (zimny cache) / tiles: fastest mode per test
# ------------------------------------------------------------------------------
def tiles(S, lang):
    t = TXT[lang]
    out = []
    for test in ("T1a", "T1b", "T2", "T4"):
        cand = [(S[(test, "cold", m)]["median"], m) for m in MODES if (test, "cold", m) in S]
        if not cand:
            continue
        best_ms, best = min(cand)
        rel = S[(test, "cold", best)].get("rel", 1)
        out.append((t[test].split(" · ")[0], t[test].split(" · ")[1], best,
                    fmt_ms(best_ms, lang), fmt_rel(rel, best, lang)))
    return out


# ------------------------------------------------------------------------------
# RESULTS.md / RESULTS_PL.md
# ------------------------------------------------------------------------------
MD = {
    "en": {
        "h1": "# 📊 Results — PostgreSQL 18 io_method: sync vs worker vs io_uring",
        "goal": "> 🎯 Measured medians for every test, cache state and `io_method`, generated from the raw CSV by "
                "`report/make_report.py`. Polish version: [RESULTS_PL.md](RESULTS_PL.md) · "
                "interactive page: [GitHub Pages]({pages}).",
        "src": "Source: `{csv}` · {n} accepted measurements · {rej} rejected (plan check)",
        "h_find": "## 🔎 Key findings",
        "h_over": "## 🧭 Overview — main run (SATA controller)",
        "h_cold": "## 🧊 Cold cache — main run (PostgreSQL restarted, OS page cache dropped before every run)",
        "h_warm": "## 🔥 Warm cache — main run (data already in shared_buffers)",
        "h_tab": "## 📋 All numbers",
        "tab_note": "Median, min, max and p90 of {runs} interleaved series. *vs sync* = ratio of medians. "
                    "*I/O read* = median of `I/O Timings: shared read` from `EXPLAIN (ANALYZE, BUFFERS)`; with parallel "
                    "workers or asynchronous I/O it sums waits across processes and is not wall-clock time.",
        "h_env": "## 🖥️ Environment",
        "h_meth": "## 🔗 Method",
        "meth": "How the tests were chosen and run: [METHODOLOGY.md](METHODOLOGY.md) · "
                "how to reproduce: [INSTALL.md](INSTALL.md) · raw data: [`results/`](../results/).",
        "alt": "chart",
    },
    "pl": {
        "h1": "# 📊 Wyniki — PostgreSQL 18 io_method: sync vs worker vs io_uring",
        "goal": "> 🎯 Mediany dla każdego testu, stanu cache i `io_method`, wygenerowane z surowego CSV przez "
                "`report/make_report.py`. Wersja angielska: [RESULTS.md](RESULTS.md) · "
                "strona interaktywna: [GitHub Pages]({pages}index_pl.html).",
        "src": "Źródło: `{csv}` · {n} przyjętych pomiarów · {rej} odrzuconych (kontrola planu)",
        "h_find": "## 🔎 Najważniejsze wnioski",
        "h_over": "## 🧭 Przegląd — główny pomiar (kontroler SATA)",
        "h_cold": "## 🧊 Zimny cache — główny pomiar (restart PostgreSQL i wyczyszczony cache stron systemu przed każdym pomiarem)",
        "h_warm": "## 🔥 Ciepły cache — główny pomiar (dane już w shared_buffers)",
        "h_tab": "## 📋 Wszystkie liczby",
        "tab_note": "Mediana, min, max i p90 z {runs} przeplatanych serii. *vs sync* = stosunek median. "
                    "*Odczyt I/O* = mediana `I/O Timings: shared read` z `EXPLAIN (ANALYZE, BUFFERS)`; przy równoległych "
                    "workerach lub asynchronicznym I/O to suma oczekiwań wielu procesów, a nie czas zegarowy.",
        "h_env": "## 🖥️ Środowisko",
        "h_meth": "## 🔗 Metoda",
        "meth": "Jak dobrano i uruchomiono testy: [METHODOLOGY_PL.md](METHODOLOGY_PL.md) · "
                "jak powtórzyć: [INSTALL_PL.md](INSTALL_PL.md) · surowe dane: [`results/`](../results/).",
        "alt": "wykres",
    },
}

PAGES_URL = "https://krzysztof-i-cabaj.github.io/pg18-io-methods-lab/"


def badges(S, runs, lang):
    pl = lang == "pl"
    return " ".join([
        "[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-18.6-336791)]()",
        "[![io_method](https://img.shields.io/badge/io__method-sync_%7C_worker_%7C_io__uring-blue)]()",
        f"[![Runs](https://img.shields.io/badge/{'Serie' if pl else 'Series'}-{runs}_{'przeplatanych' if pl else 'interleaved'}-success)]()",
        f"[![Plans](https://img.shields.io/badge/{'Kontrola_planu' if pl else 'Plan_check'}-{'każdy_pomiar' if pl else 'every_run'}-success)]()",
    ])


def write_md(S, meta, lang, charts_rel):
    m = MD[lang]
    t = TXT[lang]
    parts = [m["h1"], "", badges(S, meta["runs"], lang), "", m["goal"].format(pages=PAGES_URL), "",
             m["src"].format(csv=meta["csv"], n=meta["n"], rej=meta["rej"]), ""]
    find = read_findings(lang)
    if find:
        parts += [m["h_find"], "", find, ""]
    parts += [m["h_over"], "", f"![{m['alt']}]({charts_rel}/overview_{lang}.svg)", ""]
    if meta.get("control"):
        C, cm = meta["control"]
        parts += [f"## 🔁 {CT[lang]['h']}", "", f"*{CT[lang]['s']}*", "",
                  f"![{m['alt']}]({charts_rel}/control_nvme_{lang}.svg)", "",
                  CT[lang]["note"].format(csv=cm["csv"], n=cm["n"], rej=cm["rej"]), "", md_compare(S, C, lang), ""]
    parts += [m["h_cold"], ""]
    for test, cache in PANELS:
        if cache == "warm" and m["h_warm"] not in parts:
            parts += [m["h_warm"], ""]
        parts += [f"![{e(t[test])} — {t[cache]}]({charts_rel}/{test}_{cache}_{lang}.svg)", ""]
    parts += [m["h_tab"], "", m["tab_note"].format(runs=meta["runs"]), "", md_table(S, lang), ""]
    parts += [m["h_env"], "", "| | |", "|---|---|"]
    parts += [f"| **{k}** | {v} |" for k, v in env_facts(lang)]
    parts += ["", m["h_meth"], "", m["meth"], "", "---", "",
              "© KCB Consulting · Krzysztof Cabaj" + (" · wygenerowano" if lang == "pl" else " · generated")
              + f" {meta['generated']}", ""]
    return "\n".join(parts)


# ------------------------------------------------------------------------------
# GitHub Pages: docs/index.html (EN) + docs/index_pl.html (PL)
# ------------------------------------------------------------------------------
def css_vars(d):
    return ";".join(f"--{k}:{v}" for k, v in d.items())


PAGE_CSS = """
:root{%LIGHT%;--page:#f9f9f7;--border:rgba(11,11,11,.10);--accent:#2a78d6;color-scheme:light}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){%DARK%;--page:#0d0d0d;--border:rgba(255,255,255,.10);--accent:#6da7ec;color-scheme:dark}}
:root[data-theme="dark"]{%DARK%;--page:#0d0d0d;--border:rgba(255,255,255,.10);--accent:#6da7ec;color-scheme:dark}
*{box-sizing:border-box}
html,body{margin:0;background:var(--page);color:var(--ink)}
body{font:16px/1.6 system-ui,-apple-system,"Segoe UI",sans-serif}
a{color:var(--accent)}
.wrap{max-width:860px;margin:0 auto;padding-left:max(16px,env(safe-area-inset-left,0px));padding-right:max(16px,env(safe-area-inset-right,0px))}
header{padding:40px 0 8px}
.top{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;
     font-size:14px;color:var(--ink2)}
.top nav{display:flex;gap:8px;align-items:center}
.btn{font:inherit;font-size:13px;color:var(--ink2);background:var(--surface);border:1px solid var(--border);
     border-radius:999px;padding:4px 12px;text-decoration:none;cursor:pointer}
.btn:hover{color:var(--ink)}
h1{font-size:clamp(26px,4.4vw,38px);line-height:1.15;margin:28px 0 10px;letter-spacing:-.01em}
.lede{font-size:18px;color:var(--ink2);margin:0 0 6px;max-width:680px}
.src{font-size:13px;color:var(--muted)}
h2{font-size:21px;margin:48px 0 12px;letter-spacing:-.005em}
h2 small{font-weight:400;color:var(--muted);font-size:14px;margin-left:6px}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin:28px 0 0}
.tile{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:14px 16px}
.tile .lbl{font-size:13px;color:var(--ink2);min-height:2.9em}
.tile .val{font-size:26px;font-weight:600;margin:4px 0 2px;display:flex;align-items:center;gap:8px}
.tile .sub{font-size:13px;color:var(--ink2)}
.key{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:6px;vertical-align:baseline}
.tile .key{width:12px;height:12px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:12px;margin:12px 0;overflow:hidden}
.card svg{display:block;width:100%;height:auto}
.findings{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:4px 22px}
.findings li{margin:8px 0}
.note{font-size:14px;color:var(--ink2)}
.tablewrap{overflow-x:auto;border:1px solid var(--border);border-radius:12px;background:var(--surface)}
table{border-collapse:collapse;width:100%;font-size:14px}
th,td{padding:7px 12px;border-bottom:1px solid var(--grid);text-align:left;white-space:nowrap}
th{font-weight:600;color:var(--ink2);font-size:13px}
tbody tr:last-child td{border-bottom:0}
.r{text-align:right}.num{font-variant-numeric:tabular-nums}
dl{display:grid;grid-template-columns:max-content 1fr;gap:6px 18px;font-size:15px;
   background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:16px 20px;margin:0}
dt{color:var(--ink2)} dd{margin:0}
code{font-size:.9em;background:var(--grid);padding:1px 5px;border-radius:4px}
footer{margin:56px 0 40px;padding-top:16px;border-top:1px solid var(--border);font-size:13px;color:var(--muted)}
#tip{position:fixed;pointer-events:none;z-index:9;background:var(--surface);color:var(--ink);
     border:1px solid var(--border);border-radius:8px;padding:6px 10px;font-size:13px;
     box-shadow:0 4px 18px rgba(0,0,0,.18);max-width:320px;display:none}
[data-tip]{cursor:default;outline:none}
[data-tip]:focus-visible{stroke:var(--ink);stroke-width:1}
@media (max-width:560px){dl{grid-template-columns:1fr}dt{margin-top:6px}
  .card{overflow-x:auto;-webkit-overflow-scrolling:touch}.card svg{min-width:620px}}
"""

PAGE_JS = """
(function(){
  var root=document.documentElement, KEY='pgio-theme';
  try{var s=localStorage.getItem(KEY); if(s) root.dataset.theme=s;}catch(e){}
  var b=document.getElementById('theme');
  function label(){var d=root.dataset.theme||(matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light');
    b.textContent=d==='dark'?'☀︎':'☾';}
  label();
  b.addEventListener('click',function(){
    var d=root.dataset.theme||(matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light');
    root.dataset.theme=d==='dark'?'light':'dark'; try{localStorage.setItem(KEY,root.dataset.theme);}catch(e){} label();});
  var tip=document.getElementById('tip');
  function show(el,x,y){tip.textContent=el.getAttribute('data-tip');tip.style.display='block';
    var w=tip.offsetWidth,h=tip.offsetHeight;
    tip.style.left=Math.min(x+14,innerWidth-w-8)+'px';tip.style.top=Math.max(8,y-h-12)+'px';}
  document.querySelectorAll('[data-tip]').forEach(function(el){
    var t=el.querySelector('title'); if(t) t.remove();
    el.addEventListener('pointermove',function(ev){show(el,ev.clientX,ev.clientY);});
    el.addEventListener('pointerleave',function(){tip.style.display='none';});
    el.addEventListener('focus',function(){var r=el.getBoundingClientRect();show(el,r.left+r.width/2,r.top);});
    el.addEventListener('blur',function(){tip.style.display='none';});
  });
})();
"""

PG = {
    "en": {
        "title": "PostgreSQL 18 io_method benchmark",
        "h1": "PostgreSQL 18 asynchronous I/O: sync vs worker vs io_uring",
        "lede": "Same VM, same 13 GB table, same queries — only <code>io_method</code> changes. "
                "Every run re-checks the execution plan. In this VM <code>sync</code> was fastest for bitmap heap scans "
                "and VACUUM on two different disk controllers; the io_uring gain on full scans depended on the controller.",
        "src": "{n} accepted measurements · {rej} rejected · {runs} interleaved series · generated {gen}",
        "tiles": "Fastest mode · main run (SATA controller), cold cache",
        "find": "Key findings", "over": "Overview · main run (SATA)", "cold": "Cold cache · main run",
        "cold_s": "PostgreSQL restarted and OS page cache dropped before every run",
        "warm": "Warm cache · main run", "warm_s": "data already in shared_buffers",
        "tab": "All numbers", "env": "Environment", "meth": "Method & reproduction",
        "meth_t": '<a href="{repo}/blob/main/docs/METHODOLOGY.md">Methodology</a> · '
                  '<a href="{repo}/blob/main/docs/INSTALL.md">Install &amp; run</a> · '
                  '<a href="{repo}/tree/main/results">Raw data (CSV, plans)</a> · '
                  '<a href="{repo}/blob/main/docs/RESULTS.md">Results as Markdown</a>',
        "other": "Polski", "other_href": "index_pl.html", "repo": "Repository",
        "bars": "Bars = median · whiskers = min–max · hover a bar for details.",
    },
    "pl": {
        "title": "PostgreSQL 18 io_method — benchmark",
        "h1": "Asynchroniczne I/O w PostgreSQL 18: sync vs worker vs io_uring",
        "lede": "Ta sama VM, ta sama tabela 13 GB, te same zapytania — zmienia się tylko <code>io_method</code>. "
                "Każdy pomiar sprawdza plan wykonania. W tej VM <code>sync</code> był najszybszy przy Bitmap Heap Scan "
                "i VACUUM na dwóch różnych kontrolerach dysku; zysk io_uring przy pełnych skanach zależał od kontrolera.",
        "src": "{n} przyjętych pomiarów · {rej} odrzuconych · {runs} przeplatanych serii · wygenerowano {gen}",
        "tiles": "Najszybszy tryb · główny pomiar (kontroler SATA), zimny cache",
        "find": "Najważniejsze wnioski", "over": "Przegląd · główny pomiar (SATA)", "cold": "Zimny cache · główny pomiar",
        "cold_s": "restart PostgreSQL i wyczyszczony cache stron systemu przed każdym pomiarem",
        "warm": "Ciepły cache · główny pomiar", "warm_s": "dane już w shared_buffers",
        "tab": "Wszystkie liczby", "env": "Środowisko", "meth": "Metoda i powtórzenie testu",
        "meth_t": '<a href="{repo}/blob/main/docs/METHODOLOGY_PL.md">Metodyka</a> · '
                  '<a href="{repo}/blob/main/docs/INSTALL_PL.md">Instalacja i uruchomienie</a> · '
                  '<a href="{repo}/tree/main/results">Surowe dane (CSV, plany)</a> · '
                  '<a href="{repo}/blob/main/docs/RESULTS_PL.md">Wyniki w Markdown</a>',
        "other": "English", "other_href": "index.html", "repo": "Repozytorium",
        "bars": "Słupek = mediana · wąsy = min–max · najedź na słupek, by zobaczyć szczegóły.",
    },
}


def write_html(S, meta, lang):
    p = PG[lang]
    t = TXT[lang]
    css = PAGE_CSS.replace("%LIGHT%", css_vars(LIGHT)).replace("%DARK%", css_vars(DARK)) + SVG_CLASSES
    out = [f'<!doctype html><html lang="{lang}"><head><meta charset="utf-8">'
           f'<meta name="viewport" content="width=device-width,initial-scale=1">'
           f'<title>{e(p["title"])}</title><style>{css}</style></head><body><div class="wrap">']
    out.append(f'<header><div class="top"><span>pg18-io-methods-lab</span><nav>'
               f'<a class="btn" href="{REPO_URL}">{p["repo"]}</a>'
               f'<a class="btn" href="{p["other_href"]}" hreflang="{"pl" if lang == "en" else "en"}">{p["other"]}</a>'
               f'<button class="btn" id="theme" type="button" aria-label="theme">☾</button></nav></div>'
               f'<h1>{p["h1"]}</h1><p class="lede">{p["lede"]}</p>'
               f'<p class="src">{e(p["src"].format(n=meta["n"], rej=meta["rej"], runs=meta["runs"], gen=meta["generated"]))}</p>'
               f'</header>')
    out.append(f'<h2>{p["tiles"]}</h2><div class="tiles">')
    for tid, name, best, val, rel in tiles(S, lang):
        out.append(f'<div class="tile"><div class="lbl">{e(tid)} · {e(name)}</div>'
                   f'<div class="val"><span class="key" style="background:var(--{best})"></span>{e(best)}</div>'
                   f'<div class="sub">{e(val)} · {e(rel)}</div></div>')
    out.append("</div>")
    find = read_findings(lang)
    if find:
        out.append(f'<h2>{p["find"]}</h2><div class="findings">{md_to_html(find)}</div>')
    out.append(f'<h2>{p["over"]}</h2><div class="card">{svg_overview(S, lang, False)}</div>')
    if meta.get("control"):
        C, cm = meta["control"]
        note = CT[lang]["note"].format(csv=cm["csv"], n=cm["n"], rej=cm["rej"]).replace("`", "")
        out.append(f'<h2>{e(CT[lang]["h"])}<small>{e(CT[lang]["s"])}</small></h2>'
                   f'<div class="card">{svg_compare(S, C, lang, False)}</div><p class="note">{e(note)}</p>'
                   + html_compare(S, C, lang))
    out.append(f'<h2>{p["cold"]}<small>{p["cold_s"]}</small></h2><p class="note">{p["bars"]}</p>')
    warm_done = False
    for test, cache in PANELS:
        if cache == "warm" and not warm_done:
            out.append(f'<h2>{p["warm"]}<small>{p["warm_s"]}</small></h2>')
            warm_done = True
        out.append(f'<div class="card">{svg_panel(test, cache, S, lang, False)}</div>')
    out.append(f'<h2>{p["tab"]}</h2><p class="note">{e(MD[lang]["tab_note"].format(runs=meta["runs"]).replace("*", "").replace("`", ""))}</p>')
    out.append(html_table(S, lang))
    out.append(f'<h2>{p["env"]}</h2><dl>' + "".join(f"<dt>{e(k)}</dt><dd>{e(v)}</dd>" for k, v in env_facts(lang)) + "</dl>")
    out.append(f'<h2>{p["meth"]}</h2><p>{p["meth_t"].format(repo=REPO_URL)}</p>')
    out.append(f'<footer>© KCB Consulting · Krzysztof Cabaj · <a href="{REPO_URL}">{REPO_URL.replace("https://", "")}</a></footer>')
    out.append(f'</div><div id="tip" role="tooltip"></div><script>{PAGE_JS}</script></body></html>')
    return "".join(out)


# ------------------------------------------------------------------------------
# main
# ------------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="pg18-io-methods-lab report generator")
    ap.add_argument("--csv", help="raw CSV (default: newest results/raw_*.csv)")
    ap.add_argument("--out", default=str(ROOT / "docs"), help="output dir (default: docs/)")
    ap.add_argument("--control", help="control-run CSV (default: newest results/control_nvme/raw_*.csv, if any)")
    ap.add_argument("--dry-run", action="store_true", help="print summary only, write nothing")
    a = ap.parse_args()

    if a.csv:
        csv_path = Path(a.csv)
    else:
        cands = sorted((ROOT / "results").glob("raw_*.csv"))
        if not cands:
            sys.exit("Brak results/raw_*.csv / no raw CSV found (use --csv)")
        csv_path = cands[-1]
    rows, rejected = load(csv_path)
    S = summarize(rows)
    from datetime import date
    try:
        rel_csv = csv_path.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        rel_csv = csv_path.name
    meta = {"csv": rel_csv, "n": len(rows), "rej": len(rejected),
            "runs": max((r["series"] for r in rows), default=0), "generated": date.today().isoformat()}

    ctl = Path(a.control) if a.control else next(iter(sorted((ROOT / "results" / "control_nvme").glob("raw_*.csv"), reverse=True)), None)
    if ctl:
        crow, crej = load(ctl)
        C = summarize(crow)
        try:
            crel = ctl.resolve().relative_to(ROOT).as_posix()
        except ValueError:
            crel = ctl.name
        meta["control"] = (C, {"csv": crel, "n": len(crow), "rej": len(crej)})
        print(f"CONTROL: {ctl}  accepted={len(crow)}  rejected={len(crej)}")
        for test in CTESTS:
            print("  " + test + "  " + "  ".join(f"{m}={fmt_ms(C[(test, 'cold', m)]['median'], 'en')} (x{C[(test, 'cold', m)]['rel']:.2f})"
                                                 for m in MODES if (test, "cold", m) in C))
    print(f"CSV: {csv_path}  przyjete/accepted={meta['n']}  odrzucone/rejected={meta['rej']}  serie/series={meta['runs']}")
    for test, cache in PANELS:
        line = [f"{test:4} {cache:4}"]
        for m in MODES:
            s = S.get((test, cache, m))
            if s:
                line.append(f"{m}={fmt_ms(s['median'], 'en')} (n={s['n']}, x{s.get('rel', 1):.2f})")
        print("  " + "  ".join(line))
    if a.dry_run:
        print("DRY-RUN: nic nie zapisano / nothing written")
        return

    out = Path(a.out)
    charts = out / "charts"
    charts.mkdir(parents=True, exist_ok=True)
    written = []
    for lang in ("en", "pl"):
        (charts / f"overview_{lang}.svg").write_text(svg_overview(S, lang, True), encoding="utf-8")
        if meta.get("control"):
            (charts / f"control_nvme_{lang}.svg").write_text(svg_compare(S, meta["control"][0], lang, True), encoding="utf-8")
            written.append(charts / f"control_nvme_{lang}.svg")
        written.append(charts / f"overview_{lang}.svg")
        for test, cache in PANELS:
            if any((test, cache, m) in S for m in MODES):
                f = charts / f"{test}_{cache}_{lang}.svg"
                f.write_text(svg_panel(test, cache, S, lang, True), encoding="utf-8")
                written.append(f)
        md = out / ("RESULTS.md" if lang == "en" else "RESULTS_PL.md")
        md.write_text(write_md(S, meta, lang, "charts"), encoding="utf-8")
        page = out / ("index.html" if lang == "en" else "index_pl.html")
        page.write_text(write_html(S, meta, lang), encoding="utf-8")
        written += [md, page]
    print(f"Zapisano / written: {len(written)} plikow w {out}")


if __name__ == "__main__":
    main()
