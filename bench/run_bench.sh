#!/usr/bin/env bash
# ==============================================================================
# Tytul:        run_bench.sh
# Opis:         Pomiar trybow io_method PG18 (sync / worker / io_uring) dla testow z
#               tests.conf (T1a, T1b, T2, T3) przy zimnym i cieplym cache oraz VACUUM (T4).
#               Serie przeplatane miedzy trybami; przed kazdym pomiarem kontrola planu
#               (brak oczekiwanego wezla = plan_ok=0, wynik odrzucany w raporcie).
#               Wynik: results/raw_<ts>.csv, plany JSON w results/plans/, log w results/.
# Description [EN]: Measures PG18 io_method modes (sync / worker / io_uring) for the
#               tests in tests.conf at cold and warm cache, plus VACUUM (T4). Series are
#               interleaved across modes; every measurement re-checks the plan node.
#
# Autor:        KCB Kris
# Data:         2026-10-15
# Wersja:       1.1
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - root na VM, tabela fakty (sql/01_create_test_data.sql), io_uring odblokowany
# Requirements [EN]: - root on the VM, table fakty, io_uring enabled in the kernel
#
# Uzycie [PL]:       RUNS=1 bash run_bench.sh            (proba)
#                    RUNS=7 bash run_bench.sh            (pelny pomiar)
#                    DRY_RUN=1 bash run_bench.sh         (tylko plan dzialan)
# Usage [EN]:        same
# ==============================================================================
set -uo pipefail

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="${CONF:-$BENCH_DIR/tests.conf}"
RUNS="${RUNS:-7}"
MODES="${MODES:-sync worker io_uring}"
DO_VACUUM="${DO_VACUUM:-1}"
# Cieply cache tylko dla testow, ktorych dane mieszcza sie w RAM. Tabela fakty (13 GB) = 3,6x RAM:
# w probie 2026-10-15 cieply T1a = 53,7 s vs zimny 58,9 s — "cieply" pelny skan jest praktycznie zimny.
# Warm cache only for tests whose data fits in RAM; a warm full scan of a 13 GB table is practically cold.
WARM_TESTS="${WARM_TESTS:-T2 T3}"
DRY_RUN="${DRY_RUN:-0}"
TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_DIR:-/root/pgio/results}"
CSV="$OUT_DIR/raw_${TS}.csv"
PLANS="$OUT_DIR/plans_${TS}"
PGBIN=/usr/pgsql-18/bin
PSQL="sudo -u postgres $PGBIN/psql -XAtq -v ON_ERROR_STOP=1"
SVC=postgresql-18

log() { printf '%s [bench] %s\n' "$(date +%H:%M:%S)" "$*"; }

# --- przygotowanie / setup -----------------------------------------------------
mkdir -p "$OUT_DIR" "$PLANS"
mapfile -t TESTS < <(grep -vE '^\s*(#|$)' "$CONF")
log "testy: ${#TESTS[@]}, tryby: $MODES, serie: $RUNS, cieply cache: $WARM_TESTS, VACUUM: $DO_VACUUM"
if [[ "$DRY_RUN" == "1" ]]; then
    for r in $(seq 1 "$RUNS"); do for m in $MODES; do
        echo "seria $r / $m: restart z io_method=$m; zimny cache x${#TESTS[@]}; cieply x${#TESTS[@]}; VACUUM=$DO_VACUUM"
    done; done
    exit 0
fi

pg_wait() { for _ in $(seq 1 60); do $PGBIN/pg_isready -q && return 0; sleep 0.5; done; log "PG nie wstal"; exit 1; }
pg_restart_cold() {           # zimny cache: PG stop + opróżnienie page cache + start
    systemctl stop "$SVC"; sync; echo 3 > /proc/sys/vm/drop_caches; systemctl start "$SVC"; pg_wait
}
set_mode() {
    $PSQL -c "ALTER SYSTEM SET io_method = '$1'" >/dev/null
    pg_restart_cold
    local cur; cur=$($PSQL -c "show io_method")
    [[ "$cur" == "$1" ]] || { log "io_method=$cur, oczekiwano $1 — przerywam"; exit 1; }
}

echo "ts,series,io_method,test,cache,plan_ok,exec_ms,shared_hit,shared_read,io_read_ms,note" > "$CSV"

# Parsowanie EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) / parse EXPLAIN JSON
parse_py='
import json, sys
expect, raw = sys.argv[1], sys.argv[2]
d = json.loads(raw)[0]
p = d["Plan"]
names = []
def walk(n):
    names.append(("Parallel " if n.get("Parallel Aware") else "") + n["Node Type"])
    for c in n.get("Plans", []): walk(c)
walk(p)
ok = 1 if expect in names else 0
io = p.get("Shared I/O Read Time", p.get("I/O Read Time", 0.0))
ex = d["Execution Time"]
hit = p.get("Shared Hit Blocks", 0)
rd = p.get("Shared Read Blocks", 0)
print("%d,%.3f,%d,%d,%.3f" % (ok, ex, hit, rd, io))
'

measure() {   # $1 series  $2 mode  $3 cache  $4 test-line
    local series=$1 mode=$2 cache=$3 id expect gucs query json res
    IFS='|' read -r id expect gucs query <<<"$4"
    json=$($PSQL -c "$gucs EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, FORMAT JSON) $query") || { log "BLAD $id"; return; }
    res=$(python3 -c "$parse_py" "$expect" "$json")
    echo "$(date +%FT%T),$series,$mode,$id,$cache,$res," >> "$CSV"
    [[ "$series" == "1" && "$cache" == "cold" ]] && printf '%s\n' "$json" > "$PLANS/${id}_${mode}.json"
    log "s$series $mode $id $cache -> $res"
}

vacuum_prep() {   # identyczny stan przed kazdym VACUUM / identical state before every VACUUM
    $PSQL >/dev/null <<'SQL'
DROP TABLE IF EXISTS fakty_vac;
CREATE TABLE fakty_vac WITH (autovacuum_enabled = off) AS SELECT * FROM fakty WHERE id <= 10000000;
CREATE INDEX fakty_vac_d_idx ON fakty_vac (d);
DELETE FROM fakty_vac WHERE id % 10 = 0;
CHECKPOINT;
SQL
}
measure_vacuum() {   # $1 series $2 mode
    vacuum_prep
    pg_restart_cold
    local t0 t1 out note
    t0=$(date +%s%N)
    out=$($PSQL -c "VACUUM (VERBOSE) fakty_vac" 2>&1)
    t1=$(date +%s%N)
    note=$(grep -oE 'tuples: [0-9]+ removed|frozen: [0-9]+ pages' <<<"$out" | head -2 | tr '\n' ';' | tr -d ',')
    local us=$(( (t1 - t0) / 1000 ))                     # mikrosekundy -> ms z 3 miejscami / us -> ms.mmm
    echo "$(date +%FT%T),$1,$2,T4,cold,1,$(( us / 1000 )).$(printf '%03d' $(( us % 1000 ))),,,,${note}" >> "$CSV"
    log "s$1 $2 T4 VACUUM -> $(( (t1 - t0) / 1000000 )) ms ($note)"
}

# --- pomiar / measurement --------------------------------------------------------
$PSQL -c "ALTER TABLE fakty SET (autovacuum_enabled = off)" >/dev/null   # tabela statyczna / static table
$PSQL -c "CHECKPOINT" >/dev/null
for series in $(seq 1 "$RUNS"); do
    for mode in $MODES; do
        set_mode "$mode"
        for t in "${TESTS[@]}"; do pg_restart_cold; measure "$series" "$mode" cold "$t"; done
        for t in "${TESTS[@]}"; do
            IFS='|' read -r tid _ gucs query <<<"$t"
            [[ " $WARM_TESTS " == *" $tid "* ]] || continue
            $PSQL -c "$gucs $query" >/dev/null          # rozgrzewka / warm-up
            measure "$series" "$mode" warm "$t"
        done
        [[ "$DO_VACUUM" == "1" ]] && measure_vacuum "$series" "$mode"
    done
done

$PSQL -c "ALTER SYSTEM RESET io_method" >/dev/null; systemctl restart "$SVC"; pg_wait
$PSQL -c "DROP TABLE IF EXISTS fakty_vac" >/dev/null
log "KONIEC / DONE: $CSV ($(($(wc -l < "$CSV") - 1)) wierszy), plany: $PLANS"
