#!/usr/bin/env bash
# ==============================================================================
# Tytul:        upgrade_check.sh
# Opis:         Test U: pg_upgrade --check z klastra PG18 (/pgdata/18/data, dziala) do
#               pustego pomocniczego klastra PG19 (/pgdata/19/upgcheck, kodowanie i locale
#               jak w 18, nigdy nie startowany). Tryby copy i link. Klaster 18 tylko czytany.
#               Pomocniczy klaster usuwany na koncu (CLEANUP=1, domyslnie).
# Description [EN]: Test U: pg_upgrade --check from the PG18 cluster (running) to an empty
#               helper PG19 cluster (/pgdata/19/upgcheck, encoding and locale as in 18,
#               never started). Copy and link modes. The PG18 cluster is only read.
#               The helper cluster is removed at the end (CLEANUP=1, default).
#
# Autor:        KCB Kris
# Data:         2026-11-23
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - root na VM, PG18 dziala na 5432, PG19 zainstalowany (guest/install_pg19.sh)
# Requirements [EN]: - root on the VM, PG18 running on 5432, PG19 installed
#
# Uzycie [PL]:       bash upgrade_check.sh               (CLEANUP=0 zostawia klaster pomocniczy)
#                    DRY_RUN=1 bash upgrade_check.sh     (tylko podglad)
# Usage [EN]:        same
# ==============================================================================
set -uo pipefail
BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_TAG=upgcheck
# shellcheck source=common.sh
source "$BENCH_DIR/common.sh"

TS="${TS:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR="${OUT_DIR:-$LAB_DIR/results/upgrade_check_$TS}"
NEW_DATA=/pgdata/19/upgcheck
OLD_DATA=/pgdata/18/data
CLEANUP="${CLEANUP:-1}"
DRY_RUN="${DRY_RUN:-0}"

# --- KROK 1: podglad / preview ----------------------------------------------------
pg_env 18
systemctl is-active -q postgresql-18 || { systemctl start postgresql-18; pg_wait; }
cd /tmp || exit 1
IFS='|' read -r enc prov coll ctype <<< "$($PSQL -d postgres -c \
    "SELECT pg_encoding_to_char(encoding), datlocprovider, datcollate, datctype FROM pg_database WHERE datname = 'template1'")"
cs=$($PSQL -d postgres -c "SHOW data_checksums")
log "PG18: kodowanie ${enc}, provider ${prov}, collate ${coll}, ctype ${ctype}, checksums ${cs}"
[[ "$prov" == "c" ]] || die "provider locale ${prov} (oczekiwano libc 'c') — dopisac obsluge / extend the script"
ck_opt="--data-checksums"; [[ "$cs" == "on" ]] || ck_opt="--no-data-checksums"
initdb_cmd="/usr/pgsql-19/bin/initdb -D $NEW_DATA -E $enc --locale-provider=libc --lc-collate=$coll --lc-ctype=$ctype $ck_opt"
log "initdb: $initdb_cmd"
if [[ "$DRY_RUN" == "1" ]]; then
    echo "plan: $initdb_cmd -> pg_upgrade --check (copy) i --check --link -> $OUT_DIR -> CLEANUP=$CLEANUP"
    exit 0
fi
[[ -x /usr/pgsql-19/bin/pg_upgrade ]] || die "brak PG19 — najpierw guest/install_pg19.sh"
[[ -e "$NEW_DATA" ]] && die "$NEW_DATA juz istnieje — usun recznie albo CLEANUP z poprzedniego uruchomienia"

# --- KROK 2: pusty klaster 19 i --check / empty 19 cluster and --check --------------
mkdir -p "$OUT_DIR" "$NEW_DATA"
chown postgres:postgres "$NEW_DATA" "$OUT_DIR"; chmod 700 "$NEW_DATA"
restorecon -R /pgdata/19 2>/dev/null || true
sudo -u postgres $initdb_cmd > "$OUT_DIR/initdb.log" 2>&1 || die "initdb: $(tail -3 "$OUT_DIR/initdb.log")"

for mode in copy link; do
    flag=""; [[ "$mode" == "link" ]] && flag="--link"
    # pg_upgrade zapisuje pliki w katalogu biezacym i w pg_upgrade_output.d nowego klastra
    # pg_upgrade writes into the current directory and the new cluster's pg_upgrade_output.d
    ( cd "$OUT_DIR" && sudo -u postgres /usr/pgsql-19/bin/pg_upgrade --check $flag \
        -b /usr/pgsql-18/bin -B /usr/pgsql-19/bin -d "$OLD_DATA" -D "$NEW_DATA" -p 5432 -P 5434 \
        > "$OUT_DIR/check_${mode}.txt" 2>&1 )
    rc=$?
    log "pg_upgrade --check ${mode}: rc=${rc} -> check_${mode}.txt"
    grep -E 'fatal|failed|\*failure\*|Clusters are compatible' "$OUT_DIR/check_${mode}.txt" | sed 's/^/    /'
    cp -r "$NEW_DATA/pg_upgrade_output.d" "$OUT_DIR/output_${mode}.d" 2>/dev/null || true
done

# --- KROK 3: sprzatanie / cleanup ---------------------------------------------------
if [[ "$CLEANUP" == "1" ]]; then
    rm -rf "$NEW_DATA"
    log "usunieto klaster pomocniczy / removed helper cluster $NEW_DATA"
fi
chmod -R a+rX "$OUT_DIR"
log "KONIEC / done -> $OUT_DIR"
