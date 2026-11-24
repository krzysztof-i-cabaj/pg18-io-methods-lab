#!/usr/bin/env bash
# ==============================================================================
# Tytul:        preflight.sh
# Opis:         Karta srodowiska i kontrola przed pomiarem (tylko odczyt): system, dysk
#               danych i kontroler, wolne miejsce, pakiety PG, uslugi, porty i ustawienia
#               obu klastrow, ktore roznia sie domyslnie miedzy 18 a 19 (jit, io_*,
#               wal_level, max_repack_replication_slots...), narzedzia (pgbench, python3).
#               Klaster niedzialajacy jest pomijany — skrypt niczego nie startuje.
# Description [EN]: Environment card and pre-measurement check (read-only): OS, data disk
#               and controller, free space, PG packages, services, ports and the settings
#               of both clusters whose defaults differ between 18 and 19, tools.
#               A stopped cluster is skipped — the script starts nothing.
#
# Autor:        KCB Kris
# Data:         2026-11-23
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - root na VM pgio
# Requirements [EN]: - root on VM pgio
#
# Uzycie [PL]:       .\lab.ps1 preflight   (zapis do results\preflight_<ts>.txt na hoscie)
# Usage [EN]:        .\lab.ps1 preflight
# ==============================================================================
set -uo pipefail
cd /tmp || exit 1

echo "## System"
echo "data VM: $(date '+%F %T')"
hostname; cat /etc/rocky-release; uname -r
echo "CPU: $(nproc)  RAM: $(free -m | awk '/^Mem:/ {print $2}') MB"

echo; echo "## Dysk danych / data disk"
src=$(findmnt -no SOURCE /pgdata 2>/dev/null || echo brak)
echo "/pgdata: $src"
df -h /pgdata 2>/dev/null | tail -1
if [[ "$src" != brak ]]; then
    dev=$(lsblk -no PKNAME "$src" 2>/dev/null); dev=${dev:-$(basename "$src")}
    echo "urzadzenie / device: $dev  (nvme* = kontroler NVMe, sd* = SATA)"
    echo "scheduler: $(cat /sys/block/$dev/queue/scheduler 2>/dev/null)  rotational: $(cat /sys/block/$dev/queue/rotational 2>/dev/null)  nr_requests: $(cat /sys/block/$dev/queue/nr_requests 2>/dev/null)"
fi
du -sh /pgdata/18 /pgdata/19 2>/dev/null

echo; echo "## Pakiety i uslugi / packages and services"
rpm -q pgdg-redhat-repo postgresql18-server postgresql19-server postgresql19-contrib 2>&1
for v in 18 19; do
    echo "postgresql-$v: $(systemctl is-active postgresql-$v 2>/dev/null) / boot: $(systemctl is-enabled postgresql-$v 2>/dev/null)"
done
ss -ltn | awk 'NR==1 || /:543[2-4] /'
for t in /usr/pgsql-18/bin/pgbench /usr/pgsql-19/bin/pgbench /usr/pgsql-19/bin/pg_upgrade; do
    [[ -x $t ]] && echo "OK   $t" || echo "BRAK $t"
done
command -v python3 >/dev/null && echo "OK   python3 $(python3 -V 2>&1)" || echo "BRAK python3"

echo; echo "## Ustawienia klastrow / cluster settings"
names="'server_version','port','data_directory','data_checksums','shared_buffers','io_method','io_workers',
'io_min_workers','io_max_workers','effective_io_concurrency','jit','wal_level','effective_wal_level',
'max_wal_senders','max_replication_slots','max_repack_replication_slots','max_locks_per_transaction',
'log_lock_waits','default_toast_compression','autovacuum_max_parallel_workers','track_io_timing'"
for v in 18 19; do
    port=5432; [[ $v == 19 ]] && port=5433
    echo "### PG$v (port $port)"
    if [[ -x /usr/pgsql-$v/bin/pg_isready ]] && /usr/pgsql-$v/bin/pg_isready -q -p $port; then
        sudo -u postgres /usr/pgsql-$v/bin/psql -XAtq -p $port -d postgres -F ' = ' -c \
            "SELECT name, setting || coalesce(' ' || unit, '') FROM pg_settings WHERE name IN ($names) ORDER BY name"
        sudo -u postgres /usr/pgsql-$v/bin/psql -XAtq -p $port -d postgres -c \
            "SELECT 'baza labtest: ' || CASE WHEN EXISTS (SELECT 1 FROM pg_database WHERE datname = 'labtest') THEN 'jest' ELSE 'brak' END"
    else
        echo "(nie dziala / not running — pominiety)"
    fi
done

echo; echo "## Inne obciazenie / other load"
uptime
echo "PREFLIGHT OK"
