#!/usr/bin/env bash
# ==============================================================================
# Tytul:        provision.sh
# Opis:         Przygotowanie VM pgio: dysk danych (XFS na /pgdata), PostgreSQL 18
#               z PGDG (+ liburing), PGDATA na dysku danych, SELinux, start uslugi.
#               Idempotentny; formatuje dysk TYLKO gdy jest pusty i ma oczekiwany rozmiar.
# Description [EN]: Provision VM pgio: data disk (XFS on /pgdata), PostgreSQL 18
#               from PGDG (+ liburing), PGDATA on the data disk, SELinux, service.
#               Idempotent; formats the disk ONLY when empty and of expected size.
#
# Autor:        KCB Kris
# Data:         2026-10-15
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - Rocky 9.8 (kickstart pgio.ks), root, internet przez NAT
# Requirements [EN]: - Rocky 9.8 (pgio.ks kickstart), root, internet via NAT
#
# Uzycie [PL]:       ssh root@192.168.56.40 'bash -s' < guest/provision.sh            (zmiany)
#                    ssh root@192.168.56.40 'DRY_RUN=1 bash -s' < guest/provision.sh  (podglad)
# Usage [EN]:        same; DRY_RUN=1 = preview only
# ==============================================================================
set -euo pipefail

DATA_MIN_GB="${DATA_MIN_GB:-35}"     # oczekiwany dysk danych ~40 GB / expected ~40 GB
# Dysk danych wykrywany, nie zakladany (/dev/sdX nie sa stabilne): jedyny dysk bez partycji,
# >= DATA_MIN_GB; albo juz zamontowany pod /pgdata. / Detect, don't assume /dev/sdX.
if [[ -z "${DATA_DEV:-}" ]]; then
    if src=$(findmnt -no SOURCE /pgdata 2>/dev/null); then
        DATA_DEV="$src"
    else
        mapfile -t cand < <(lsblk -dnbo NAME,SIZE,TYPE | awk -v min=$((DATA_MIN_GB*1024*1024*1024)) \
            '$3=="disk" && $1 ~ /^(sd|vd|nvme)/ && $2>=min {print "/dev/"$1}' | while read -r d; do
                [[ $(lsblk -n -o NAME "$d" | wc -l) -eq 1 ]] && echo "$d"; done)
        (( ${#cand[@]} == 1 )) || { echo "[provision] oczekiwany 1 pusty dysk >= ${DATA_MIN_GB} GB, jest: ${cand[*]:-brak}"; exit 1; }
        DATA_DEV="${cand[0]}"
    fi
fi
MOUNT_POINT="/pgdata"
PGVER=18
PGDATA="${MOUNT_POINT}/${PGVER}/data"
DRY_RUN="${DRY_RUN:-0}"

log()  { printf '[provision] %s\n' "$*"; }
run()  { if [[ "$DRY_RUN" == "1" ]]; then printf '[dry-run] %s\n' "$*"; else eval "$@"; fi; }

# --- KROK 1: podglad / preview ------------------------------------------------
log "host: $(hostname)  kernel: $(uname -r)"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
[[ -b "$DATA_DEV" ]] || { log "BRAK $DATA_DEV / missing data disk"; exit 1; }
size_gb=$(( $(blockdev --getsize64 "$DATA_DEV") / 1024 / 1024 / 1024 ))
sig=$(wipefs -n "$DATA_DEV" | tail -n +2 | wc -l)
log "$DATA_DEV: ${size_gb} GB, sygnatury/signatures: ${sig}"
(( size_gb >= DATA_MIN_GB )) || { log "dysk za maly (<${DATA_MIN_GB} GB) — przerywam / too small"; exit 1; }
children=$(( $(lsblk -n -o NAME "$DATA_DEV" | wc -l) - 1 ))
if ! findmnt -n "$MOUNT_POINT" >/dev/null && (( children > 0 )); then
    log "$DATA_DEV ma partycje/LVM (${children}) — to nie pusty dysk danych, przerywam / not an empty data disk"
    exit 1
fi

# --- KROK 2: dysk danych / data disk ------------------------------------------
if findmnt -n "$MOUNT_POINT" >/dev/null; then
    log "$MOUNT_POINT juz zamontowany / already mounted — pomijam"
elif (( sig == 0 )); then
    run "mkfs.xfs -q -L pgdata '$DATA_DEV'"
    run "mkdir -p '$MOUNT_POINT'"
    run "echo 'LABEL=pgdata $MOUNT_POINT xfs defaults,noatime 0 0' >> /etc/fstab"
    run "systemctl daemon-reload"
    run "mount '$MOUNT_POINT'"
else
    log "$DATA_DEV ma sygnatury, ale nie jest zamontowany — nie formatuje / has signatures, not formatting"
    exit 1
fi

# --- KROK 3: PostgreSQL 18 z PGDG / from PGDG ---------------------------------
if ! rpm -q "postgresql${PGVER}-server" >/dev/null 2>&1; then
    run "dnf -y -q install https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
    run "dnf -y -q module disable postgresql || true"
    run "dnf -y -q install postgresql${PGVER}-server postgresql${PGVER}-contrib liburing sysstat policycoreutils-python-utils"
else
    log "postgresql${PGVER}-server juz zainstalowany / already installed"
fi

# --- KROK 4: PGDATA na dysku danych + SELinux ---------------------------------
run "mkdir -p '$PGDATA' && chown -R postgres:postgres '${MOUNT_POINT}/${PGVER}' && chmod 700 '$PGDATA'"
run "semanage fcontext -a -t postgresql_db_t '${MOUNT_POINT}(/.*)?' 2>/dev/null || semanage fcontext -m -t postgresql_db_t '${MOUNT_POINT}(/.*)?'"
run "restorecon -R '$MOUNT_POINT'"
run "mkdir -p /etc/systemd/system/postgresql-${PGVER}.service.d"
run "printf '[Service]\nEnvironment=PGDATA=%s\n' '$PGDATA' > /etc/systemd/system/postgresql-${PGVER}.service.d/pgdata.conf"
run "systemctl daemon-reload"

if [[ ! -f "$PGDATA/PG_VERSION" ]]; then
    run "PGSETUP_INITDB_OPTIONS='--data-checksums' /usr/pgsql-${PGVER}/bin/postgresql-${PGVER}-setup initdb"
else
    log "klaster juz zainicjowany / cluster already initialised"
fi

# --- KROK 5: konfiguracja (identyczna dla trybow; zmienia sie tylko io_method) --
run "mkdir -p '$PGDATA/conf.d' && chown postgres:postgres '$PGDATA/conf.d'"
run "grep -q \"^include_dir = 'conf.d'\" '$PGDATA/postgresql.conf' || echo \"include_dir = 'conf.d'\" >> '$PGDATA/postgresql.conf'"
run "cat > '$PGDATA/conf.d/10-lab.conf' <<'EOF'
# pg18-io-methods-lab: wspolne ustawienia / common settings
listen_addresses = 'localhost'
shared_buffers = '1GB'
track_io_timing = on
EOF"
run "chown postgres:postgres '$PGDATA/conf.d/10-lab.conf'"
run "systemctl enable --now postgresql-${PGVER}"

# --- KROK 6: weryfikacja / verification ----------------------------------------
if [[ "$DRY_RUN" != "1" ]]; then
    findmnt "$MOUNT_POINT"
    sudo -u postgres /usr/pgsql-${PGVER}/bin/psql -XAtc "select version(); show data_directory; show io_method; show shared_buffers;"
fi
log "OK"
