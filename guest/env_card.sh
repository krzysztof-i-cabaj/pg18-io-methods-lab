#!/usr/bin/env bash
# ==============================================================================
# Tytul:        env_card.sh
# Opis:         Karta srodowiska VM pgio (tylko odczyt): OS, kernel, CPU, RAM, dysk
#               danych, wersja PG, obsluga liburing i io_uring. Wynik do results/.
# Description [EN]: Environment card for VM pgio (read-only): OS, kernel, CPU, RAM,
#               data disk, PG version, liburing and io_uring availability.
#
# Autor:        KCB Kris
# Data:         2026-10-15
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - po guest/provision.sh, root
# Requirements [EN]: - after guest/provision.sh, root
#
# Uzycie [PL]:       ssh root@192.168.56.40 'bash -s' < guest/env_card.sh > results/env_card.txt
# Usage [EN]:        same
# ==============================================================================
set -uo pipefail
PGBIN=/usr/pgsql-18/bin
sec() { printf '\n## %s\n' "$*"; }

sec "OS / kernel";        cat /etc/rocky-release; uname -r
sec "CPU";                lscpu | grep -E '^(Model name|CPU\(s\)|Thread|Core|Socket|Hypervisor)'
sec "RAM";                free -m
sec "Dyski / disks";      lsblk -o NAME,SIZE,ROTA,TYPE,FSTYPE,MOUNTPOINT
sec "Dysk danych / data disk"
findmnt /pgdata
for q in scheduler rotational nr_requests read_ahead_kb; do printf '%s: %s\n' "$q" "$(cat /sys/block/sdb/queue/$q 2>/dev/null)"; done
sec "io_uring (kernel)";  sysctl kernel.io_uring_disabled 2>&1; rpm -q liburing
sec "PostgreSQL";         sudo -u postgres $PGBIN/psql -XAtc "select version();"
printf 'pg_config --configure zawiera liburing: '; $PGBIN/pg_config --configure | grep -q -- '--with-liburing' && echo TAK || echo NIE
sudo -u postgres $PGBIN/psql -XAtc "select name||' = '||setting||coalesce(' '||unit,'') from pg_settings where name in ('io_method','io_workers','io_combine_limit','io_max_combine_limit','effective_io_concurrency','maintenance_io_concurrency','shared_buffers','track_io_timing','max_parallel_workers_per_gather') order by 1;"
sec "Dozwolone wartosci io_method / allowed values"
sudo -u postgres $PGBIN/psql -XAtc "select enumvals from pg_settings where name='io_method';"
