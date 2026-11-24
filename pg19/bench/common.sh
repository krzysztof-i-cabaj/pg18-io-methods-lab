#!/usr/bin/env bash
# ==============================================================================
# Tytul:        common.sh
# Opis:         Wspolne funkcje testow PG18 vs PG19 na VM pgio: wybor klastra
#               (bin, port, usluga), restart na zimno jednego klastra (drugi zatrzymany),
#               psql bez hasla jako postgres, baza testowa labtest.
# Description [EN]: Shared helpers for PG18 vs PG19 tests on VM pgio: cluster selection
#               (bin, port, service), cold restart of one cluster (the other stopped),
#               password-less psql as postgres, test database labtest.
#
# Autor:        KCB Kris
# Data:         2026-11-23
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - root na VM, PG18 (port 5432) i PG19 (port 5433) z PGDG
# Requirements [EN]: - root on the VM, PG18 (port 5432) and PG19 (port 5433) from PGDG
#
# Uzycie [PL]:       source "$(dirname "$0")/common.sh"; pg_env 19; only_cluster
# Usage [EN]:        same
# ==============================================================================

LAB_DIR="${LAB_DIR:-/root/pg19lab}"
DB="${DB:-labtest}"

log() { printf '%s [%s] %s\n' "$(date +%H:%M:%S)" "${LOG_TAG:-lab}" "$*"; }
die() { log "BLAD / ERROR: $*"; exit 1; }

# Ustawia PGV, PGBIN, PGPORT, SVC, PSQL, PSQLDB dla wersji 18 lub 19.
# Sets PGV, PGBIN, PGPORT, SVC, PSQL, PSQLDB for version 18 or 19.
pg_env() {
    PGV="$1"
    case "$PGV" in
        18) PGPORT=5432 ;;
        19) PGPORT=5433 ;;
        *)  die "nieznana wersja / unknown version: $PGV" ;;
    esac
    PGBIN="/usr/pgsql-${PGV}/bin"
    SVC="postgresql-${PGV}"
    [[ -x "$PGBIN/psql" ]] || die "brak $PGBIN/psql — PG${PGV} niezainstalowany / not installed"
    PSQL="sudo -u postgres $PGBIN/psql -XAtq -v ON_ERROR_STOP=1 -p $PGPORT"
    PSQLDB="$PSQL -d $DB"
}

pg_wait() {
    for _ in $(seq 1 120); do "$PGBIN/pg_isready" -q -p "$PGPORT" && return 0; sleep 0.5; done
    die "PG${PGV} nie wstal / did not come up"
}

# Mierzony klaster jako jedyny dzialajacy, start na zimno (pusty page cache).
# Only the measured cluster runs, cold start (empty page cache).
only_cluster() {
    local v
    for v in 18 19; do
        [[ "$v" == "$PGV" ]] && continue
        systemctl stop "postgresql-${v}" 2>/dev/null || true
    done
    systemctl stop "$SVC"
    sync
    echo 3 > /proc/sys/vm/drop_caches
    systemctl start "$SVC"
    pg_wait
}

# Baza testowa (osobna od postgres, gdzie lezy fakty) / test DB, separate from postgres
ensure_db() {
    if [[ -z "$($PSQL -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$DB'")" ]]; then
        $PSQL -d postgres -c "CREATE DATABASE $DB" >/dev/null
        log "utworzono baze / created database $DB w PG${PGV}"
    fi
}

now_s() { date +%s.%N; }
ms_between() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.0f", (b - a) * 1000 }'; }
