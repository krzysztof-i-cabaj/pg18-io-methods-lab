# ==============================================================================
# Tytul:        Network.psm1
# Opis:         Idempotentne tworzenie/aktualizacja host-only network 'vboxnet0'
#               (192.168.56.0/24, DHCP off) zgodnie z VBox 7.0+ syntax.
# Description [EN]: Idempotent host-only network 'vboxnet0' creation/update
#               (192.168.56.0/24, DHCP off), VBox 7.0+ syntax.
#
# Autor:        KCB Kris
# Data:         2026-05-02
# Wersja:       1.0
# <repo>:       <repo>
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - VirtualBox 7.0+
# Requirements [EN]: - VirtualBox 7.0+
#
# Uzycie [PL]:       Initialize-LabNetwork -Name vboxnet0 -HostIp 192.168.56.1
# Usage [EN]:        Initialize-LabNetwork -Name vboxnet0 -HostIp 192.168.56.1
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force -DisableNameChecking

function Get-LabHostonlyAdapter {
    [CmdletBinding()]
    param([string]$Cidr = '192.168.56.0/24')
    $vbox = Get-VBoxManagePath
    if (-not $vbox) { throw 'VBoxManage.exe not found.' }

    # VBoxManage list hostonlyifs -- returns blocks of "Name: ...", "IPAddress: ...", etc.
    $raw = & $vbox list hostonlyifs
    if (-not $raw) { return $null }

    $blocks = ($raw -join "`n") -split "(`r?`n){2,}"
    foreach ($b in $blocks) {
        $name = ([regex]::Match($b, '(?m)^Name:\s*(.+)$')).Groups[1].Value.Trim()
        $ip   = ([regex]::Match($b, '(?m)^IPAddress:\s*(.+)$')).Groups[1].Value.Trim()
        if ($name) {
            # Match by 192.168.56.x prefix (lab network)
            if ($ip -like '192.168.56.*') {
                return @{ Name = $name; IpAddress = $ip }
            }
        }
    }
    return $null
}

function Initialize-LabNetwork {
    [CmdletBinding()]
    param(
        [string]$HostIp = '192.168.56.1',
        [string]$Netmask = '255.255.255.0'
    )

    Write-Step "Network: ensure host-only adapter at $HostIp"

    $vbox = Get-VBoxManagePath
    if (-not $vbox) { throw 'VBoxManage.exe not found.' }

    $existing = Get-LabHostonlyAdapter -Cidr '192.168.56.0/24'

    if ($existing) {
        Write-Ok "Found existing host-only adapter: $($existing.Name) at $($existing.IpAddress)"
        if ($existing.IpAddress -ne $HostIp) {
            Write-Log -Level Info -Message "Updating IP from $($existing.IpAddress) to $HostIp"
            & $vbox hostonlyif ipconfig $existing.Name --ip $HostIp --netmask $Netmask | Out-Null
        }
        # Disable DHCP to be safe
        & $vbox dhcpserver remove --ifname $existing.Name 2>$null | Out-Null
        return $existing.Name
    }

    Write-Log -Level Info -Message 'Creating new host-only adapter...'
    $created = & $vbox hostonlyif create
    # Output looks like: "Interface 'VirtualBox Host-Only Ethernet Adapter #2' was successfully created"
    $name = ([regex]::Match(($created -join ' '), "'([^']+)'")).Groups[1].Value
    if (-not $name) {
        throw "Could not parse host-only adapter name from VBoxManage output: $created"
    }
    Write-Ok "Created adapter: $name"

    & $vbox hostonlyif ipconfig $name --ip $HostIp --netmask $Netmask | Out-Null
    & $vbox dhcpserver remove --ifname $name 2>$null | Out-Null

    return $name
}

function Remove-LabNetwork {
    [CmdletBinding()]
    param()
    $vbox = Get-VBoxManagePath
    if (-not $vbox) { return }
    $existing = Get-LabHostonlyAdapter
    if (-not $existing) {
        Write-Log -Level Info -Message 'No lab host-only adapter to remove.'
        return
    }
    & $vbox hostonlyif remove $existing.Name | Out-Null
    Write-Ok "Removed adapter: $($existing.Name)"
}

Export-ModuleMember -Function 'Get-LabHostonlyAdapter', 'Initialize-LabNetwork', 'Remove-LabNetwork'
