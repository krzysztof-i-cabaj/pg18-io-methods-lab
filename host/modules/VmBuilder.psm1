# ==============================================================================
# Tytul:        VmBuilder.psm1
# Opis:         Tworzenie/usuwanie/listing VMek przez VBoxManage. Idempotentne
#               New-LabVm: tworzy VMke z 2 NICami (hostonly + nat), VDI 20 GB,
#               podpina ISO. Remove-LabVm: poweroff + unregister + delete VDI.
# Description [EN]: VM create/remove/list via VBoxManage. Idempotent New-LabVm:
#               creates VM with 2 NICs (hostonly + nat), 20 GB VDI, attaches ISO.
#               Remove-LabVm: poweroff + unregister + delete VDI.
#
# Autor:        KCB Kris
# Data:         2026-05-02
# Wersja:       1.0
# <repo>:       <repo>
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - VirtualBox 7.0+, host-only adapter juz utworzony
# Requirements [EN]: - VirtualBox 7.0+, host-only adapter already created
#
# Uzycie [PL]:       New-LabVm -Name pg1 -Ram 4096 -Cpu 2 -HostonlyAdapter vboxnet0 -IsoPath ...
#                    Remove-LabVm -Name pg1
# Usage [EN]:        New-LabVm -Name pg1 -Ram 4096 -Cpu 2 -HostonlyAdapter vboxnet0 -IsoPath ...
#                    Remove-LabVm -Name pg1
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force -DisableNameChecking

function Test-VmExists {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $vbox = Get-VBoxManagePath
    $list = & $vbox list vms
    return ($list -match "`"$Name`"" -ne $null)
}

function Get-VmState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $vbox = Get-VBoxManagePath
    try {
        $info = & $vbox showvminfo $Name --machinereadable 2>$null
        if (-not $info) { return 'absent' }
        $state = ([regex]::Match(($info -join "`n"), '(?m)^VMState="(.+?)"')).Groups[1].Value
        return $state
    } catch { return 'absent' }
}

function New-LabVm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Ram,
        [Parameter(Mandatory)][int]$Cpu,
        [Parameter(Mandatory)][string]$HostonlyAdapter,
        [Parameter(Mandatory)][string]$IsoPath,
        [int]$DiskMb = 20480,
        [string]$OsType = 'RedHat_64',
        # pg18-io-methods-lab: osobny dysk danych (PGDATA), staly rozmiar (Fixed), 0 = brak.
        # pg18-io-methods-lab: separate data disk (PGDATA), fixed size; 0 = none.
        [int]$DataDiskMb = 0
    )

    $vbox = Get-VBoxManagePath
    if (-not $vbox) { throw 'VBoxManage.exe not found.' }

    Write-Step "VM: ensure '$Name' (RAM=${Ram}MB, vCPU=$Cpu, disk=${DiskMb}MB)"

    if (Test-VmExists -Name $Name) {
        Write-Log -Level Info -Message "VM '$Name' already registered, skipping create."
        return
    }

    & $vbox createvm --name $Name --ostype $OsType --register | Out-Null

    # Boot: DYSK przed DVD. Pusty dysk przy 1. boocie przepada do DVD (instalator
    # rusza z kickstartem), a po instalacji dysk jest bootowalny -> boot z dysku.
    # NIE odwracac na 'dvd disk': VBox z DVD na SATA ignoruje `reboot --eject`, wiec
    # po instalacji VM bootowalaby DVD ponownie i odpalala instalator w petli.
    # Boot: DISK before DVD. Empty disk on 1st boot falls through to DVD (installer
    # runs the kickstart); after install the disk is bootable. Do NOT flip to
    # 'dvd disk' -- VBox ignores `reboot --eject` for a SATA DVD -> re-install loop.
    & $vbox modifyvm $Name `
        --memory $Ram `
        --cpus $Cpu `
        --nic1 hostonly `
        --hostonlyadapter1 $HostonlyAdapter `
        --nic2 nat `
        --boot1 disk --boot2 dvd --boot3 none --boot4 none `
        --ioapic on `
        --rtcuseutc on `
        --graphicscontroller vmsvga `
        --vram 16 `
        --audio-driver none | Out-Null

    # Storage: SATA controller + VDI + DVD
    $vmFolder = & $vbox showvminfo $Name --machinereadable | Where-Object { $_ -like 'CfgFile=*' }
    $vmDir = Split-Path -Parent (([regex]::Match($vmFolder, 'CfgFile="(.+)"')).Groups[1].Value)
    $vdi = Join-Path $vmDir "$Name.vdi"

    & $vbox createmedium disk --filename $vdi --size $DiskMb --format VDI | Out-Null
    # --hostiocache off JAWNIE: przy wlaczonym cache Windows buforuje odczyty dysku VM
    # i "zimny cache" w goscu przestaje byc zimny (kluczowe dla pomiarow I/O).
    # --hostiocache off EXPLICITLY: with it on, Windows caches VM disk reads and a
    # "cold cache" inside the guest is no longer cold (critical for I/O measurements).
    & $vbox storagectl $Name --name SATA --add sata --controller IntelAhci --portcount 3 --hostiocache off | Out-Null
    # --nonrotational on: host to NVMe, gosc ma widziec SSD (rotational=0) / guest should see an SSD
    & $vbox storageattach $Name --storagectl SATA --port 0 --type hdd --medium $vdi --nonrotational on | Out-Null
    & $vbox storageattach $Name --storagectl SATA --port 1 --type dvddrive --medium $IsoPath | Out-Null

    if ($DataDiskMb -gt 0) {
        # Dysk danych: Fixed (prealokowany) -> brak narzutu rozrastania pliku VDI w trakcie testu.
        # Data disk: Fixed (preallocated) -> no VDI growth overhead during measurements.
        $dataVdi = Join-Path $vmDir "$Name-data.vdi"
        Write-Log -Level Info -Message "Creating FIXED data disk ${DataDiskMb}MB: $dataVdi (may take a while)"
        & $vbox createmedium disk --filename $dataVdi --size $DataDiskMb --format VDI --variant Fixed | Out-Null
        & $vbox storageattach $Name --storagectl SATA --port 2 --type hdd --medium $dataVdi --nonrotational on | Out-Null
    }

    Write-Ok "Created VM '$Name'"
}

function Remove-LabVm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$Force
    )

    $vbox = Get-VBoxManagePath
    if (-not $vbox) { return }
    if (-not (Test-VmExists -Name $Name)) {
        Write-Log -Level Info -Message "VM '$Name' not registered, skipping."
        return
    }

    $state = Get-VmState -Name $Name
    if ($state -eq 'running') {
        Write-Log -Level Info -Message "Powering off '$Name'..."
        & $vbox controlvm $Name poweroff 2>$null | Out-Null
        Start-Sleep -Seconds 2
    }

    & $vbox unregistervm $Name --delete 2>$null | Out-Null
    Write-Ok "Removed VM '$Name'"
}

function Detach-LabVmIso {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $vbox = Get-VBoxManagePath
    if (-not $vbox) { return }
    & $vbox storageattach $Name --storagectl SATA --port 1 --type dvddrive --medium none 2>$null | Out-Null
    & $vbox modifyvm $Name --boot1 disk --boot2 none 2>$null | Out-Null
    Write-Ok "Detached ISO from '$Name', boot order set to disk."
}

function Start-LabVm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('headless','gui')][string]$Type = 'headless'
    )
    $vbox = Get-VBoxManagePath
    & $vbox startvm $Name --type $Type | Out-Null
    Write-Ok "Started VM '$Name' (type=$Type)"
}

function Get-LabVms {
    [CmdletBinding()]
    param([string[]]$Names)
    $vbox = Get-VBoxManagePath
    $result = @()
    foreach ($n in $Names) {
        if (Test-VmExists -Name $n) {
            $result += [pscustomobject]@{
                Name  = $n
                State = (Get-VmState -Name $n)
            }
        }
    }
    return $result
}

Export-ModuleMember -Function `
    'Test-VmExists', 'Get-VmState', 'New-LabVm', 'Remove-LabVm', `
    'Detach-LabVmIso', 'Start-LabVm', 'Get-LabVms'
