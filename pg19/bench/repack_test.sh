#!/usr/bin/env bash
# ==============================================================================
# Tytul:        repack_test.sh
# Opis:         Test R, jedna seria jednego wariantu: rozdeta tabela bloat_t, zapisujacy
#               klient pgbench (UPDATE, log co 1 s), po WARMUP s operacja porzadkujaca
#               (VACUUM FULL / REPACK / REPACK (CONCURRENTLY)), po COOLDOWN s koniec klienta.
#               Wynik: wiersz w $CSV + os czasu tps co sekunde w $OUT_DIR/timeline_*.csv.
# Description [EN]: Test R, one series of one variant: bloated table bloat_t, a writing
#               pgbench client (UPDATE, 1 s aggregate log), after WARMUP s the maintenance
#               command, after COOLDOWN s the client is stopped. Output: a row in $CSV
#               plus a per-second tps timeline in $OUT_DIR/timeline_*.csv.
#
# Autor:        KCB Kris
# Data:         2026-11-23
# Wersja:       1.2  (1.1: DROP bloat_t po serii, tps w oknie operacji; 1.2: kolumna clients, c<N> w nazwach plikow)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - root na VM, bench/common.sh, sql/10_bloat_table.sql, pgbench z PGDG;
#                      REPACK tylko w PG19
# Requirements [EN]: - root on the VM, bench/common.sh, sql/10_bloat_table.sql, PGDG pgbench;
#                      REPACK only in PG19
#
# Uzycie [PL]:       PGV=19 VARIANT=repack_concurrently RUN=1 bash repack_test.sh
#                    DRY_RUN=1 PGV=18 VARIANT=vacuum_full bash repack_test.sh   (tylko podglad)
#                    (zwykle wywoluje run_all.sh)
# Usage [EN]:        same (normally called by run_all.sh)
# ==============================================================================
set -uo pipefail
BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_TAG=repack
# shellcheck source=common.sh
source "$BENCH_DIR/common.sh"

PGV="${PGV:?PGV=18|19}"
VARIANT="${VARIANT:?VARIANT=vacuum_full|repack|repack_concurrently}"
RUN="${RUN:-1}"
ROWS="${ROWS:-20000000}"
WARMUP="${WARMUP:-10}"
COOLDOWN="${COOLDOWN:-10}"
CLIENTS="${CLIENTS:-4}"
TS="${TS:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR="${OUT_DIR:-$LAB_DIR/results/repack_$TS}"
CSV="${CSV:-$LAB_DIR/results/repack_$TS.csv}"
DRY_RUN="${DRY_RUN:-0}"

case "$VARIANT" in
    vacuum_full)          MAINT_SQL="VACUUM FULL bloat_t" ;;
    repack)               MAINT_SQL="REPACK bloat_t" ;;
    repack_concurrently)  MAINT_SQL="REPACK (CONCURRENTLY) bloat_t" ;;
    *) die "nieznany wariant / unknown variant: $VARIANT" ;;
esac
[[ "$VARIANT" == repack* && "$PGV" != "19" ]] && die "REPACK istnieje od PG19 / exists since PG19"

log "PG${PGV} ${VARIANT} seria ${RUN}: ${ROWS} wierszy, ${CLIENTS} klientow, warmup ${WARMUP}s, cooldown ${COOLDOWN}s"
log "operacja / command: ${MAINT_SQL}"
if [[ "$DRY_RUN" == "1" ]]; then
    echo "plan: only_cluster ${PGV} -> 10_bloat_table.sql rows=${ROWS} -> only_cluster (zimny) -> pgbench writer.sql"
    echo "      -> sleep ${WARMUP} -> ${MAINT_SQL} -> sleep ${COOLDOWN} -> pg_terminate_backend(pgbench) -> CSV ${CSV}"
    exit 0
fi

cd /tmp || exit 1
pg_env "$PGV"
mkdir -p "$OUT_DIR"
WORK="$OUT_DIR/work_${PGV}_${VARIANT}_c${CLIENTS}_${RUN}"
rm -rf "$WORK"; mkdir -p "$WORK"; cp "$BENCH_DIR/writer.sql" "$WORK/"; chown -R postgres:postgres "$WORK"

# --- KROK 1: tabela rozdeta / bloated table -------------------------------------
only_cluster
ensure_db
$PSQLDB -v rows="$ROWS" -f "$LAB_DIR/sql/10_bloat_table.sql" > "$WORK/setup.log" 2>&1 || die "setup bloat_t: $(tail -3 "$WORK/setup.log")"
only_cluster      # zimny cache przed pomiarem / cold cache before the measurement
size_q="SELECT round(pg_relation_size('bloat_t')/1048576.0, 1), round(pg_indexes_size('bloat_t')/1048576.0, 1)"
IFS='|' read -r tbl_before idx_before <<< "$($PSQLDB -c "$size_q")"
log "przed / before: tabela ${tbl_before} MB, indeksy ${idx_before} MB"

# --- KROK 2: zapisujacy klient / writing client ----------------------------------
maxhalf=$(( ROWS / 2 - 1 ))
w_start=$(now_s)
( cd "$WORK" && sudo -u postgres "$PGBIN/pgbench" -n -p "$PGPORT" -c "$CLIENTS" -j 1 -T 3600 -P 1 \
      --log --aggregate-interval=1 --log-prefix=pgb -D maxhalf="$maxhalf" -f writer.sql "$DB" \
      > "$WORK/pgbench.out" 2> "$WORK/pgbench_progress.log" ) &
pgb_pid=$!
sleep "$WARMUP"

# --- KROK 3: operacja / maintenance command --------------------------------------
t0=$(now_s)
$PSQLDB -c "$MAINT_SQL" > "$WORK/maint.log" 2>&1
maint_rc=$?
t1=$(now_s)
maint_ms=$(ms_between "$t0" "$t1")
log "operacja / command: rc=${maint_rc}, ${maint_ms} ms"
[[ $maint_rc -ne 0 ]] && log "komunikat / message: $(tr '\n' ' ' < "$WORK/maint.log")"
sleep "$COOLDOWN"
t_end=$(now_s)

# Koniec klienta przez zamkniecie jego sesji: pgbench konczy sie sam i zapisuje logi
# (SIGINT ubilby go bez zrzutu bufora logu). / Stop the client by terminating its sessions:
# pgbench exits on its own and flushes its logs (SIGINT would lose the buffered log).
$PSQL -d postgres -c "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE application_name = 'pgbench'" >/dev/null
for _ in $(seq 1 30); do kill -0 "$pgb_pid" 2>/dev/null || break; sleep 1; done
kill -0 "$pgb_pid" 2>/dev/null && { log "pgbench nie skonczyl — kill"; kill "$pgb_pid"; }
wait "$pgb_pid" 2>/dev/null

# --- KROK 4: weryfikacja / verification -----------------------------------------
IFS='|' read -r tbl_after idx_after <<< "$($PSQLDB -c "$size_q")"
rows_after=$($PSQLDB -c "SELECT count(*) FROM bloat_t")
expected=$(( ROWS / 2 ))
ok=1
[[ $maint_rc -eq 0 && "$rows_after" == "$expected" ]] || ok=0
log "po / after: tabela ${tbl_after} MB, indeksy ${idx_after} MB, wierszy ${rows_after} (oczekiwane ${expected}), ok=${ok}"

# --- KROK 5: os czasu i podsumowanie / timeline and summary -----------------------
TL="$OUT_DIR/timeline_${PGV}_${VARIANT}_c${CLIENTS}_${RUN}.csv"
summary=$(python3 - "$WORK" "$w_start" "$t0" "$t1" "$t_end" "$TL" <<'PY'
import glob, sys
work, w_start, t0, t1, t_end, tl = sys.argv[1], *map(float, sys.argv[2:6]), sys.argv[6]
agg = {}
for f in glob.glob(f"{work}/pgb.*"):
    for line in open(f):
        p = line.split()
        if len(p) < 6:
            continue
        sec, n, max_us = int(p[0]), int(p[1]), int(p[5]) if int(p[1]) else 0
        a = agg.setdefault(sec, [0, 0])
        a[0] += n
        a[1] = max(a[1], max_us)
start, end = int(w_start), int(t_end)
with open(tl, "w") as out:
    out.write("t_s,tps,max_lat_ms,phase\n")
    for sec in range(start, end + 1):
        n, mx = agg.get(sec, [0, 0])
        phase = "maint" if t0 <= sec + 0.5 <= t1 else ("before" if sec + 0.5 < t0 else "after")
        out.write(f"{sec - int(t0)},{n},{mx / 1000:.1f},{phase}\n")   # t_s = 0: sekunda startu operacji
def window(a, b, full_only):
    # full_only: tylko pelne sekundy w oknie (tlo); inaczej kazda sekunda nachodzaca na okno (operacja,
    # tez krotsza niz 1 s). / full seconds only (baseline), else every second overlapping the window.
    if full_only:
        secs = [s for s in range(int(a), int(b) + 1) if a <= s and s + 1 <= b]
    else:
        secs = list(range(int(a), int(b) + 1))
    tx = sum(agg.get(s, [0, 0])[0] for s in secs)
    zero = sum(1 for s in secs if agg.get(s, [0, 0])[0] == 0)
    return secs, tx, zero
b_secs, b_tx, _ = window(w_start + 2, t0, True)    # pierwsze 2 s = rozgrzewka polaczen
m_secs, m_tx, m_zero = window(t0, t1, False)
base_tps = b_tx / max(len(b_secs), 1)
maint_tps = m_tx / max(len(m_secs), 1)
max_lat = max([v[1] for s, v in agg.items() if t0 <= s + 0.5 <= t_end] or [0]) / 1000
print(f"{base_tps:.0f},{maint_tps:.0f},{m_zero},{max_lat:.0f}")
PY
)
[[ -n "$summary" ]] || { summary=",,,"; ok=0; log "brak logu pgbench / no pgbench log"; }
IFS=',' read -r base_tps maint_tps zero_s max_lat_ms <<< "$summary"
log "tps przed ${base_tps}, w trakcie ${maint_tps}, sekund z 0 tps ${zero_s}, maks. opoznienie ${max_lat_ms} ms"

[[ -f "$CSV" ]] || echo "ts,run,pg,variant,rows,maint_ms,tbl_before_mb,idx_before_mb,tbl_after_mb,idx_after_mb,base_tps,maint_tps,zero_tps_s,max_lat_ms,rows_after,ok,clients" > "$CSV"
echo "$(date +%F_%T),${RUN},${PGV},${VARIANT},${ROWS},${maint_ms},${tbl_before},${idx_before},${tbl_after},${idx_after},${base_tps},${maint_tps},${zero_s},${max_lat_ms},${rows_after},${ok},${CLIENTS}" >> "$CSV"
# Zwolnienie miejsca (/pgdata 40 GB, tabela i tak powstaje od nowa w kazdej serii)
# Free the space (40 GB /pgdata; the table is recreated in every series anyway)
$PSQLDB -c "DROP TABLE IF EXISTS bloat_t" >/dev/null
log "KONIEC serii / series done -> $CSV"
