# ==============================================================================
# Tytul:        BootKickstart.psm1
# Opis:         Boot VMki z wstrzykniecem boot params kickstart przez scancode.
#               Czeka na boot menu, wysyla Tab + " inst.ks=http://... ip=..." +
#               Enter. Pollery: Wait-Ssh (port 22), Wait-Dns (dig zwraca IP).
# Description [EN]: Boot VM with kickstart boot params injected via scancode.
#               Waits for boot menu, sends Tab + " inst.ks=http://... ip=..." +
#               Enter. Pollers: Wait-Ssh (port 22), Wait-Dns (dig returns IP).
#
# Autor:        KCB Kris
# Data:         2026-05-02
# Wersja:       1.0
# <repo>:       <repo>
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - VirtualBox 7.0+, Scancode.psm1, sciezka do KS server na hoscie
# Requirements [EN]: - VirtualBox 7.0+, Scancode.psm1, KS server URL on host
#
# Uzycie [PL]:       Start-VmWithKickstart -VmName pg1 -KsUrl http://192.168.56.1:8000/kickstart/pg1.ks -VmIp 192.168.56.11 -VmHostname pg1.lab.test
# Usage [EN]:        Start-VmWithKickstart -VmName pg1 -KsUrl http://192.168.56.1:8000/kickstart/pg1.ks -VmIp 192.168.56.11 -VmHostname pg1.lab.test
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Common.psm1')   -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Scancode.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'VmBuilder.psm1') -Force -DisableNameChecking

function Start-VmWithKickstart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$KsUrl,
        [Parameter(Mandatory)][string]$VmIp,
        [Parameter(Mandatory)][string]$VmHostname,
        [string]$Gateway = '192.168.56.1',
        [string]$Netmask = '255.255.255.0',
        [string]$NetDevice = 'enp0s3',
        [int]$BootMenuWaitSec = 6
    )

    Write-Step "Boot VM '$VmName' with kickstart $KsUrl"

    # GUI: kazda VM startuje we wlasnym oknie VirtualBox (widac konsole na zywo).
    # GUI: each VM starts in its own VirtualBox window (live console visible).
    Start-LabVm -Name $VmName -Type gui

    # Wait for ISOLINUX boot menu to appear
    Write-Log -Level Info -Message "Waiting $BootMenuWaitSec s for ISOLINUX menu..."
    Start-Sleep -Seconds $BootMenuWaitSec

    # Tab to enter ISOLINUX edit mode (append params to first menu entry)
    Send-VmTab -Vm $VmName
    Start-Sleep -Milliseconds 500

    # ip= bez bramy (puste pole gateway): serwer KS jest w tej samej podsieci host-only,
    # a brama na host-only bylaby slepa i psula default route. / no gateway: KS server is
    # same-subnet; a host-only gateway would be a dead end and break the default route.
    $bootLine = " inst.ks=$KsUrl inst.text ip=${VmIp}:::${Netmask}:${VmHostname}:${NetDevice}:none"
    Write-Log -Level Debug -Message "Sending boot line: $bootLine"
    Send-VmString -Vm $VmName -Text $bootLine
    Start-Sleep -Milliseconds 500

    Send-VmEnter -Vm $VmName
    Write-Ok "Boot params sent, kickstart starting on '$VmName'"
}

function Wait-Ssh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IpAddress,
        [int]$TimeoutMinutes = 30,
        [int]$IntervalSec = 10
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    Write-Log -Level Info -Message "Waiting up to ${TimeoutMinutes}m for SSH on ${IpAddress}:22 ..."
    while ((Get-Date) -lt $deadline) {
        $tcp = $null
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $async = $tcp.BeginConnect($IpAddress, 22, $null, $null)
            $ok = $async.AsyncWaitHandle.WaitOne(2000)
            if ($ok -and $tcp.Connected) {
                $tcp.EndConnect($async)
                Write-Ok "SSH up on $IpAddress"
                return $true
            }
        } catch {
            # ignore until deadline
        } finally {
            if ($tcp) { $tcp.Close() }
        }
        Start-Sleep -Seconds $IntervalSec
        Write-Host '.' -NoNewline
    }
    Write-Host ''
    throw "Timed out waiting for SSH on ${IpAddress}:22 after ${TimeoutMinutes} minutes."
}

function Wait-Dns {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DnsServer,
        [Parameter(Mandatory)][string]$Hostname,
        [int]$TimeoutMinutes = 5,
        [int]$IntervalSec = 5
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    Write-Log -Level Info -Message "Waiting up to ${TimeoutMinutes}m for DNS: $Hostname @ $DnsServer ..."
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Resolve-DnsName -Name $Hostname -Server $DnsServer -DnsOnly -QuickTimeout -ErrorAction Stop -Type A
            $ip = ($r | Where-Object Type -eq 'A' | Select-Object -First 1).IPAddress
            if ($ip) {
                Write-Ok "DNS @ $DnsServer responding: $Hostname -> $ip"
                return $true
            }
        } catch {
            # not yet
        }
        Start-Sleep -Seconds $IntervalSec
        Write-Host '.' -NoNewline
    }
    Write-Host ''
    throw "Timed out waiting for DNS '$Hostname' from $DnsServer after ${TimeoutMinutes} minutes."
}

Export-ModuleMember -Function 'Start-VmWithKickstart', 'Wait-Ssh', 'Wait-Dns'
