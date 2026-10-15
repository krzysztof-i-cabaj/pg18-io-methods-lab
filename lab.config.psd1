# ==============================================================================
# Tytul:        lab.config.psd1
# Opis:         Konfiguracja labu pg18-io-methods-lab: jedna VM Rocky 9.8 z PG18,
#               dysk danych Fixed, siec host-only + NAT, serwer kickstart na hoscie.
# Description [EN]: pg18-io-methods-lab config: one Rocky 9.8 VM with PG18, fixed
#               data disk, host-only + NAT networking, kickstart server on the host.
#
# Autor:        KCB Kris
# Data:         2026-10-15
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - ladowany przez Get-LabConfig (host/modules/Common.psm1)
# Requirements [EN]: - loaded by Get-LabConfig (host/modules/Common.psm1)
#
# Uzycie [PL]:       .\lab.ps1 plan   (podglad bez zmian)
# Usage [EN]:        .\lab.ps1 plan   (dry-run, no changes)
# ==============================================================================
@{
    Network = @{
        HostIp  = '192.168.56.1'      # adapter host-only (VirtualBox Host-Only Ethernet Adapter #2)
        Netmask = '255.255.255.0'
    }

    Vm = @{
        Name       = 'pgio'
        Hostname   = 'pgio.lab.test'
        Ip         = '192.168.56.40'  # musi byc wolny w sieci host-only (sprawdza: lab.ps1 plan)
        Ram        = 4096             # celowo maly RAM: dane testowe 3-4x RAM
        Cpu        = 4
        OsDiskMb   = 20480            # system, dynamiczny
        DataDiskMb = 40960            # PGDATA, Fixed, host I/O cache off
    }

    Iso = @{
        Path   = 'D:\ISOs\Rocky-9.8-x86_64-minimal.iso'
        Sha256 = 'd338032cd1cdd41c67139f2f71b4c832c8e4a21943106519db9c7137df7a63d4'
    }

    Ssh = @{
        KeyPath = "$env:USERPROFILE\.ssh\id_ed25519"
    }

    KsServer = @{
        BindIp = '192.168.56.1'
        Port   = 8000
    }

    Pg = @{
        Version = 18
        PgData  = '/pgdata/18/data'
    }
}
