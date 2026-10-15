#!/usr/bin/env bash
# ==============================================================================
# Tytul:        plan_check.sh
# Opis:         Kontrola planow (tylko EXPLAIN, bez wykonania): dla kazdego testu z
#               tests.conf wypisuje drzewo wezlow, szacowane wiersze i PASS/FAIL
#               (czy oczekiwany wezel wystepuje w planie). Nic nie zmienia.
# Description [EN]: Plan check (EXPLAIN only, no execution): prints node tree,
#               estimated rows and PASS/FAIL per test. Read-only.
#
# Autor:        KCB Kris
# Data:         2026-10-15
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - tabela fakty, jq niepotrzebne (python3 z systemu)
# Requirements [EN]: - table fakty, python3 from the OS
#
# Uzycie [PL]:       bash /root/bench/plan_check.sh /root/bench/tests.conf
# Usage [EN]:        bash /root/bench/plan_check.sh /root/bench/tests.conf
# ==============================================================================
set -uo pipefail
CONF="${1:-/root/bench/tests.conf}"
PSQL="sudo -u postgres /usr/pgsql-18/bin/psql -XAtq"
rc=0
echo "io_method: $($PSQL -c 'show io_method')"
while IFS='|' read -r id expect gucs query; do
    [[ -z "$id" || "$id" == \#* ]] && continue
    json=$($PSQL -c "$gucs EXPLAIN (FORMAT JSON) $query")
    nodes=$(python3 - "$json" <<'PY'
import json, sys
plan = json.loads(sys.argv[1])[0]["Plan"]
def walk(n, d=0):
    name = n["Node Type"]
    if n.get("Parallel Aware"): name = "Parallel " + name
    idx = n.get("Index Name") or n.get("Relation Name") or ""
    print("  " * d + f"{name} {idx} (rows~{int(n.get('Plan Rows', 0))})")
    for c in n.get("Plans", []): walk(c, d + 1)
walk(plan)
PY
)
    # dokladny wezel na poczatku linii: "Seq Scan" nie zalicza "Parallel Seq Scan"
    # exact node at line start: "Seq Scan" does not match "Parallel Seq Scan"
    if grep -qE -- "^ *${expect} " <<<"$nodes"; then st=PASS; else st=FAIL; rc=1; fi
    echo "=== $id  oczekiwany: $expect  => $st"
    echo "$nodes"
done < "$CONF"
exit $rc
