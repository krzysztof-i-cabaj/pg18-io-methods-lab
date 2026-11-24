#!/usr/bin/env bash
# ==============================================================================
# Tytul:        fk_test.sh
# Opis:         Test F, jedna seria jednej wersji: masowy INSERT ... SELECT do tabeli
#               zamowienie z kluczem obcym do klient (wariant fk) i bez niego (nofk,
#               kontrola). Kolejnosc wariantow zalezy od numeru serii. jit = off w sesji
#               (w PG19 domyslnie off, w PG18 on — wyrownanie). Pomiar: EXPLAIN (ANALYZE,
#               FORMAT JSON) — czas wykonania i czas triggerow RI.
# Description [EN]: Test F, one series of one version: bulk INSERT ... SELECT into
#               zamowienie with a foreign key to klient (variant fk) and without it (nofk,
#               control). Variant order depends on the series number. jit = off in the
#               session (PG19 default off, PG18 on — levelled). Measured with EXPLAIN
#               (ANALYZE, FORMAT JSON): execution time and RI trigger time.
#
# Autor:        KCB Kris
# Data:         2026-11-23
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - root na VM, bench/common.sh, sql/20_fk_tables.sql
# Requirements [EN]: - root on the VM, bench/common.sh, sql/20_fk_tables.sql
#
# Uzycie [PL]:       PGV=19 RUN=1 bash fk_test.sh
#                    DRY_RUN=1 PGV=18 bash fk_test.sh   (tylko podglad)
#                    (zwykle wywoluje run_all.sh)
# Usage [EN]:        same (normally called by run_all.sh)
# ==============================================================================
set -uo pipefail
BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_TAG=fk
# shellcheck source=common.sh
source "$BENCH_DIR/common.sh"

PGV="${PGV:?PGV=18|19}"
RUN="${RUN:-1}"
ROWS="${ROWS:-5000000}"
PARENTS="${PARENTS:-100000}"
TS="${TS:-$(date +%Y%m%d_%H%M%S)}"
CSV="${CSV:-$LAB_DIR/results/fk_$TS.csv}"
OUT_DIR="${OUT_DIR:-$LAB_DIR/results/fk_$TS}"
DRY_RUN="${DRY_RUN:-0}"

if (( RUN % 2 )); then VARIANTS="fk nofk"; else VARIANTS="nofk fk"; fi
log "PG${PGV} seria ${RUN}: ${ROWS} wierszy, ${PARENTS} klientow, kolejnosc: ${VARIANTS}"
if [[ "$DRY_RUN" == "1" ]]; then
    echo "plan: only_cluster ${PGV} -> 20_fk_tables.sql -> only_cluster (zimny) -> dla ${VARIANTS}:"
    echo "      CREATE zamowienie [REFERENCES klient] -> CHECKPOINT -> EXPLAIN ANALYZE INSERT ${ROWS} -> CSV ${CSV}"
    exit 0
fi

cd /tmp || exit 1
pg_env "$PGV"
mkdir -p "$OUT_DIR"

# --- KROK 1: tabela nadrzedna / parent table -------------------------------------
only_cluster
ensure_db
$PSQLDB -v parents="$PARENTS" -f "$LAB_DIR/sql/20_fk_tables.sql" > "$OUT_DIR/setup_${PGV}_${RUN}.log" 2>&1 \
    || die "setup klient: $(tail -3 "$OUT_DIR/setup_${PGV}_${RUN}.log")"
only_cluster      # zimny cache / cold cache

[[ -f "$CSV" ]] || echo "ts,run,pg,variant,rows,parents,exec_ms,wall_ms,trig_ms,trig_calls,rows_after,ok" > "$CSV"

for variant in $VARIANTS; do
    ref=""; [[ "$variant" == "fk" ]] && ref="REFERENCES klient (id)"
    # --- KROK 2: tabela podrzedna bez indeksow / child table without indexes ------
    $PSQLDB -c "DROP TABLE IF EXISTS zamowienie" >/dev/null
    $PSQLDB -c "CREATE TABLE zamowienie (id bigint NOT NULL, klient_id bigint NOT NULL ${ref}, kwota numeric(10,2) NOT NULL)" >/dev/null
    $PSQLDB -c "CHECKPOINT" >/dev/null

    # --- KROK 3: pomiar / measurement ---------------------------------------------
    # klient_id rozrzucony deterministycznie (bez random) / spread deterministically (no random)
    sqlf="$OUT_DIR/insert_${PGV}_${variant}_${RUN}.sql"
    cat > "$sqlf" <<EOF
SET jit = off;
EXPLAIN (ANALYZE, FORMAT JSON)
INSERT INTO zamowienie (id, klient_id, kwota)
SELECT g, 1 + (g * 2654435761) % ${PARENTS}, (g % 100000) / 100.0
FROM generate_series(1, ${ROWS}) g;
EOF
    chmod 644 "$sqlf"
    t0=$(now_s)
    json=$($PSQLDB -f "$sqlf" 2> "$OUT_DIR/insert_${PGV}_${variant}_${RUN}.err")
    rc=$?
    t1=$(now_s)
    wall_ms=$(ms_between "$t0" "$t1")
    printf '%s\n' "$json" > "$OUT_DIR/plan_${PGV}_${variant}_${RUN}.json"

    # --- KROK 4: weryfikacja i zapis / verification and record --------------------
    parsed=",,"
    if [[ $rc -eq 0 ]]; then
        parsed=$(python3 - "$json" <<'PY'
import json, sys
d = json.loads(sys.argv[1])[0]
trig = d.get("Triggers", [])
print(f'{d["Execution Time"]:.0f},{sum(t.get("Time", 0) for t in trig):.0f},{sum(t.get("Calls", 0) for t in trig)}')
PY
)
    fi
    IFS=',' read -r exec_ms trig_ms trig_calls <<< "$parsed"
    rows_after=$($PSQLDB -c "SELECT count(*) FROM zamowienie")
    ok=1; [[ $rc -eq 0 && "$rows_after" == "$ROWS" ]] || ok=0
    log "${variant}: wykonanie ${exec_ms} ms, zegar ${wall_ms} ms, triggery ${trig_ms} ms / ${trig_calls} wywolan, wierszy ${rows_after}, ok=${ok}"
    echo "$(date +%F_%T),${RUN},${PGV},${variant},${ROWS},${PARENTS},${exec_ms},${wall_ms},${trig_ms},${trig_calls},${rows_after},${ok}" >> "$CSV"
done
$PSQLDB -c "DROP TABLE IF EXISTS zamowienie" >/dev/null
log "KONIEC serii / series done -> $CSV"
