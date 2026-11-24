#!/usr/bin/env bash
# ==============================================================================
# Tytul:        run_all.sh
# Opis:         Orkiestracja pomiaru na VM: test R (serie przeplatane: PG18 VACUUM FULL,
#               PG19 VACUUM FULL, PG19 REPACK (CONCURRENTLY)), test F (serie przeplatane
#               PG18/PG19), test U (pg_upgrade --check). Wspolny znacznik czasu wynikow.
#               Na koniec przywraca stan: dziala tylko PG18 (jak przy boocie).
# Description [EN]: Measurement orchestration on the VM: test R (interleaved series),
#               test F (interleaved PG18/PG19), test U (pg_upgrade --check). Shared result
#               timestamp. Restores the state at the end: only PG18 running (as at boot).
#
# Autor:        KCB Kris
# Data:         2026-11-23
# Wersja:       1.2  (1.1: SUITE=clients; 1.2: VARIANT_C i CLIENTS_LIST z przecinkami — kontrola VACUUM FULL)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - root na VM, PG18 + PG19 (guest/install_pg19.sh), katalog /root/pg19lab
# Requirements [EN]: - root on the VM, PG18 + PG19, directory /root/pg19lab
#
# Uzycie [PL]:       SUITE=all RUNS_R=3 RUNS_F=5 bash run_all.sh       (pelny pomiar)
#                    SUITE=all TRIAL=1 bash run_all.sh                 (proba: male tabele, 1 seria)
#                    SUITE=repack|fk|upgrade ...                       (jeden test)
#                    SUITE=clients RUNS_R=3 bash run_all.sh            (czesc 2: REPACK CONC. przy 1/4/8 sesjach)
#                    DRY_RUN=1 SUITE=all bash run_all.sh               (tylko plan)
#                    (z hosta: .\lab.ps1 trial | run)
# Usage [EN]:        same
# ==============================================================================
set -uo pipefail
BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_TAG=run
# shellcheck source=common.sh
source "$BENCH_DIR/common.sh"

SUITE="${SUITE:-all}"
TRIAL="${TRIAL:-0}"
if [[ "$TRIAL" == "1" ]]; then
    RUNS_R=1; RUNS_F=1
    export ROWS_R="${ROWS_R:-400000}" ROWS_F="${ROWS_F:-200000}" WARMUP=5 COOLDOWN=5
    TAG=trial
else
    RUNS_R="${RUNS_R:-3}"; RUNS_F="${RUNS_F:-5}"
    export ROWS_R="${ROWS_R:-20000000}" ROWS_F="${ROWS_F:-5000000}"
    TAG=full
fi
export TS="${TS:-$(date +%Y%m%d_%H%M%S)}_${TAG}"
export DRY_RUN="${DRY_RUN:-0}"
RES="$LAB_DIR/results"
mkdir -p "$RES"
R_VARIANTS="${R_VARIANTS:-18:vacuum_full 19:vacuum_full 19:repack_concurrently}"

log "START suite=${SUITE} tryb=${TAG} R: ${RUNS_R}x (${R_VARIANTS}), ${ROWS_R} wierszy; F: ${RUNS_F}x, ${ROWS_F} wierszy; ts=${TS}"
t_all=$(now_s)
fail=0

if [[ "$SUITE" == all || "$SUITE" == repack ]]; then
    for r in $(seq 1 "$RUNS_R"); do
        for pv in $R_VARIANTS; do
            PGV="${pv%%:*}" VARIANT="${pv#*:}" RUN="$r" ROWS="$ROWS_R" \
                OUT_DIR="$RES/repack_$TS" CSV="$RES/repack_$TS.csv" \
                bash "$BENCH_DIR/repack_test.sh" || { fail=1; log "repack ${pv} seria ${r}: blad"; }
        done
    done
fi

if [[ "$SUITE" == all || "$SUITE" == fk ]]; then
    for r in $(seq 1 "$RUNS_F"); do
        # kolejnosc wersji tez sie zmienia / version order alternates too
        if (( r % 2 )); then order="18 19"; else order="19 18"; fi
        for v in $order; do
            PGV="$v" RUN="$r" ROWS="$ROWS_F" OUT_DIR="$RES/fk_$TS" CSV="$RES/fk_$TS.csv" \
                bash "$BENCH_DIR/fk_test.sh" || { fail=1; log "fk PG${v} seria ${r}: blad"; }
        done
    done
fi

# Czesc 2: faza koncowa REPACK (CONCURRENTLY) a liczba piszacych sesji (tylko na zyczenie, nie w "all")
# Part 2: REPACK (CONCURRENTLY) final phase vs number of writing sessions (on request only, not in "all")
if [[ "$SUITE" == clients ]]; then
    CLIENTS_LIST="${CLIENTS_LIST:-1 4 8}"
    CLIENTS_LIST="${CLIENTS_LIST//,/ }"                  # z hosta jako 1,8 (bez spacji w argumencie)
    VARIANT_C="${VARIANT_C:-repack_concurrently}"        # kontrola: VARIANT_C=vacuum_full
    log "clients: wariant ${VARIANT_C}, sesje ${CLIENTS_LIST}, serie ${RUNS_R}"
    for r in $(seq 1 "$RUNS_R"); do
        # kolejnosc rosnaca w seriach nieparzystych, malejaca w parzystych / ascending, then descending
        if (( r % 2 )); then order="$CLIENTS_LIST"; else order="$(printf '%s\n' $CLIENTS_LIST | tac | tr '\n' ' ')"; fi
        for c in $order; do
            PGV=19 VARIANT="$VARIANT_C" CLIENTS="$c" RUN="$r" ROWS="$ROWS_R" \
                OUT_DIR="$RES/repack_$TS" CSV="$RES/repack_$TS.csv" \
                bash "$BENCH_DIR/repack_test.sh" || { fail=1; log "clients c=${c} seria ${r}: blad"; }
        done
    done
fi

if [[ "$SUITE" == all || "$SUITE" == upgrade ]]; then
    OUT_DIR="$RES/upgrade_check_$TS" bash "$BENCH_DIR/upgrade_check.sh" || { fail=1; log "upgrade_check: blad"; }
fi

# Stan jak przy boocie: tylko PG18 / boot state: only PG18
if [[ "$DRY_RUN" != "1" ]]; then
    systemctl stop postgresql-19 2>/dev/null || true
    systemctl start postgresql-18
    chmod -R a+rX "$RES"
fi
log "KONIEC suite=${SUITE} fail=${fail} czas $(ms_between "$t_all" "$(now_s)") ms; wyniki: $RES/*_$TS*"
