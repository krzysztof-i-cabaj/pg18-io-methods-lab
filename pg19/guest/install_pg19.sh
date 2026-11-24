#!/usr/bin/env bash
# ==============================================================================
# Tytul:        install_pg19.sh
# Opis:         Instalacja PostgreSQL 19 z PGDG obok dzialajacego PG18 na VM pgio:
#               PGDATA /pgdata/19/data (ten sam dysk danych), port 5433, konfiguracja jak
#               w PG18 (shared_buffers 1GB, track_io_timing), checksumy jawnie wlaczone.
#               Usluga NIE startuje przy boocie (testy wlaczaja jeden klaster naraz).
#               Idempotentny; nie rusza klastra 18 ani tabeli fakty.
# Description [EN]: Installs PostgreSQL 19 from PGDG next to the running PG18 on VM pgio:
#               PGDATA /pgdata/19/data (same data disk), port 5433, same config as PG18,
#               checksums explicitly on. Service NOT enabled at boot (tests run one cluster
#               at a time). Idempotent; does not touch the 18 cluster or table fakty.
#
# Autor:        KCB Kris
# Data:         2026-11-23
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - VM pgio po guest/provision.sh labu pg18-io-methods-lab (/pgdata, repo PGDG),
#                      root, internet przez NAT, >= 12 GB wolnego na /pgdata
# Requirements [EN]: - VM pgio after pg18-io-methods-lab guest/provision.sh, root, internet
#                      via NAT, >= 12 GB free on /pgdata
#
# Uzycie [PL]:       .\lab.ps1 install -DryRun   (podglad)  |  .\lab.ps1 install   (zmiany)
# Usage [EN]:        same; DRY_RUN=1 = preview only
# ==============================================================================
set -euo pipefail

PGVER=19
PORT=5433
MOUNT_POINT=/pgdata
PGDATA="${MOUNT_POINT}/${PGVER}/data"
MIN_FREE_GB="${MIN_FREE_GB:-12}"
DRY_RUN="${DRY_RUN:-0}"

log() { printf '[install19] %s\n' "$*"; }
run() { if [[ "$DRY_RUN" == "1" ]]; then printf '[dry-run] %s\n' "$*"; else eval "$@"; fi; }

# --- KROK 1: podglad / preview --------------------------------------------------
log "host: $(hostname)  kernel: $(uname -r)"
findmnt -n "$MOUNT_POINT" >/dev/null || { log "brak $MOUNT_POINT — to nie jest VM pgio po provision.sh"; exit 1; }
free_gb=$(( $(df --output=avail -B1 "$MOUNT_POINT" | tail -1) / 1024 / 1024 / 1024 ))
log "$MOUNT_POINT wolne / free: ${free_gb} GB (wymagane >= ${MIN_FREE_GB})"
(( free_gb >= MIN_FREE_GB )) || { log "za malo miejsca / not enough space"; exit 1; }
rpm -q postgresql18-server >/dev/null 2>&1 && log "PG18: $(rpm -q postgresql18-server)" || log "PG18 nie zainstalowany (nie przeszkadza)"
log "PG18 usluga / service: $(systemctl is-active postgresql-18 2>/dev/null || true)"
if ss -ltn "sport = :${PORT}" | grep -q LISTEN; then
    [[ -f "$PGDATA/PG_VERSION" ]] || { log "port ${PORT} zajety przez cos innego niz PG19 — przerywam"; exit 1; }
fi

# --- KROK 2: pakiety PG19 z PGDG / PG19 packages from PGDG -----------------------
if ! rpm -q "postgresql${PGVER}-server" >/dev/null 2>&1; then
    # Pakiet repo z pazdziernika (PG18) moze nie znac jeszcze pgdg19 — instalacja z URL podbija go do najnowszego.
    # The October repo package may not know pgdg19 yet — installing from the URL upgrades it to the latest.
    log "repo PGDG teraz / now: $(rpm -q pgdg-redhat-repo 2>/dev/null || echo brak)"
    run "dnf -y -q install https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm || dnf -y -q upgrade pgdg-redhat-repo"
    run "dnf repolist --enabled | grep -q '^pgdg${PGVER} ' || { echo 'repo pgdg${PGVER} niewlaczone / not enabled'; exit 1; }"
    run "dnf -y -q install postgresql${PGVER}-server postgresql${PGVER}-contrib"
else
    log "postgresql${PGVER}-server juz zainstalowany / already installed: $(rpm -q postgresql${PGVER}-server)"
fi

# --- KROK 3: PGDATA na dysku danych + SELinux (kontekst /pgdata juz jest z PG18) --
run "mkdir -p '$PGDATA' && chown -R postgres:postgres '${MOUNT_POINT}/${PGVER}' && chmod 700 '$PGDATA'"
run "restorecon -R '${MOUNT_POINT}/${PGVER}'"
run "mkdir -p /etc/systemd/system/postgresql-${PGVER}.service.d"
run "printf '[Service]\nEnvironment=PGDATA=%s\n' '$PGDATA' > /etc/systemd/system/postgresql-${PGVER}.service.d/pgdata.conf"
run "systemctl daemon-reload"

if [[ ! -f "$PGDATA/PG_VERSION" ]]; then
    # Checksumy jawnie (w 19 i tak domyslne) — tak samo jak klaster 18 / explicit, same as the 18 cluster
    run "PGSETUP_INITDB_OPTIONS='--data-checksums' /usr/pgsql-${PGVER}/bin/postgresql-${PGVER}-setup initdb"
else
    log "klaster juz zainicjowany / cluster already initialised: $(cat "$PGDATA/PG_VERSION")"
fi

# --- KROK 4: konfiguracja jak w PG18 + port / same config as PG18 + port -------------
run "mkdir -p '$PGDATA/conf.d' && chown postgres:postgres '$PGDATA/conf.d'"
run "grep -q \"^include_dir = 'conf.d'\" '$PGDATA/postgresql.conf' || echo \"include_dir = 'conf.d'\" >> '$PGDATA/postgresql.conf'"
run "cat > '$PGDATA/conf.d/10-lab.conf' <<'EOF'
# pg19-vs-pg18-lab: te same ustawienia co PG18 na pgio / same settings as PG18 on pgio
listen_addresses = 'localhost'
port = 5433
shared_buffers = '1GB'
track_io_timing = on
EOF"
run "chown postgres:postgres '$PGDATA/conf.d/10-lab.conf'"
# Bez enable: przy boocie startuje tylko PG18, testy przelaczaja klastry same.
# No enable: only PG18 starts at boot; the tests switch clusters themselves.
run "systemctl start postgresql-${PGVER}"

# --- KROK 5: weryfikacja / verification ------------------------------------------
if [[ "$DRY_RUN" != "1" ]]; then
    cd /tmp
    sudo -u postgres /usr/pgsql-${PGVER}/bin/psql -XAt -p ${PORT} -c "select version(); show data_directory; show port; show data_checksums; show io_method;"
    ls -l /usr/pgsql-${PGVER}/bin/pgbench /usr/pgsql-${PGVER}/bin/pg_upgrade
fi
log "OK"
