# ==============================================================================
# Tytul:        lab.ps1
# Opis:         Sterowanie labem pg19-vs-pg18-lab z hosta (VM pgio z labu
#               pg18-io-methods-lab): status, start/stop VM, preflight (karta srodowiska),
#               install (PG19 obok PG18), push (skrypty na VM), trial (proba), run
#               (pelny pomiar w tle przez systemd-run), progress, fetch, ssh.
# Description [EN]: Host-side driver for pg19-vs-pg18-lab (VM pgio from pg18-io-methods-lab):
#               status, VM start/stop, preflight, install (PG19 next to PG18), push,
#               trial, run (background via systemd-run), progress, fetch, ssh.
#
# Autor:        KCB Kris
# Data:         2026-11-23
# Wersja:       1.2  (1.1: log przez bash -c — SELinux; 1.2: -Suite clients, -ExtraEnv)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - PowerShell 7, VirtualBox 7.x, OpenSSH, klucz %USERPROFILE%\.ssh\id_ed25519,
#                      VM pgio (192.168.56.40) z labu pg18-io-methods-lab
# Requirements [EN]: - PowerShell 7, VirtualBox 7.x, OpenSSH, key %USERPROFILE%\.ssh\id_ed25519,
#                      VM pgio (192.168.56.40) from pg18-io-methods-lab
#
# Uzycie [PL]:       .\lab.ps1 status | start [-Force] | preflight | install [-DryRun] | push |
#                              trial | run [-Suite all|repack|fk|upgrade] [-RunsR 3] [-RunsF 5] |
#                              progress | fetch | ssh | stop
# Usage [EN]:        same
# ==============================================================================
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'start', 'stop', 'preflight', 'install', 'push', 'trial', 'run', 'progress', 'fetch', 'ssh')]
    [string]$Verb = 'status',
    [ValidateSet('all', 'repack', 'fk', 'upgrade', 'clients')][string]$Suite = 'all',
    [int]$RunsR = 3,
    [int]$RunsF = 5,
    [string]$ExtraEnv = '',          # np. 'VARIANT_C=vacuum_full CLIENTS_LIST=1,8' (wartosci bez spacji)
    [switch]$DryRun,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = $PSScriptRoot
$VmName   = 'pgio'
$VmIp     = '192.168.56.40'
$KeyPath  = "$env:USERPROFILE\.ssh\id_ed25519"
$VBox     = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
$GuestDir = '/root/pg19lab'
$Unit     = 'pg19lab-run'
$sshOpts  = @('-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL', '-o', 'BatchMode=yes',
              '-o', 'ConnectTimeout=10', '-i', $KeyPath)

function Write-Step([string]$m) { Write-Host "`n== $m" -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host " OK  $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host " WARN $m" -ForegroundColor Yellow }

function Get-VmState {
    $info = & $VBox showvminfo $VmName --machinereadable 2>$null
    if (-not $info) { return 'absent' }
    return ([regex]::Match(($info -join "`n"), '(?m)^VMState="(.+?)"')).Groups[1].Value
}

function Invoke-Guest([string]$Command) {
    & ssh @sshOpts "root@$VmIp" $Command
    if ($LASTEXITCODE -ne 0) { throw "ssh exit $LASTEXITCODE : $Command" }
}

# Skrypt gościa przez stdin; PowerShell dokleja CRLF przy pipe do ssh, wiec tr -d '\r' po stronie VM.
# Guest script via stdin; PowerShell appends CRLF when piping to ssh, hence tr -d '\r' on the VM.
function Invoke-GuestScript([string]$RelPath, [string]$EnvPrefix = '') {
    Get-Content -Raw (Join-Path $RepoRoot $RelPath) | & ssh @sshOpts "root@$VmIp" "tr -d '\r' | ${EnvPrefix}bash -s"
    if ($LASTEXITCODE -ne 0) { throw "$RelPath exit $LASTEXITCODE" }
}

function Wait-Ssh([int]$TimeoutSec = 240) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        & ssh @sshOpts "root@$VmIp" 'true' 2>$null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 5
    }
    throw "SSH do $VmIp nie odpowiada po $TimeoutSec s"
}

function Start-GuestRun([string]$EnvList) {
    # systemd-run: proces na VM niezalezny od sesji SSH, terminal hosta wolny od razu.
    # systemd-run: VM process independent of the SSH session; host terminal is released at once.
    $busy = & ssh @sshOpts "root@$VmIp" "systemctl is-active $Unit 2>/dev/null"
    if ($busy -eq 'active') { throw "Na VM trwa juz pomiar ($Unit) — .\lab.ps1 progress" }
    $setenv = ($EnvList -split ' ' | Where-Object { $_ } | ForEach-Object { "--setenv=$_" }) -join ' '
    # Log otwiera bash, nie systemd: StandardOutput=append:/root/... konczy sie "Permission denied"
    # (status 209/STDOUT, SELinux, sprawdzone 2026-11-23). / bash opens the log, not systemd (SELinux denial).
    Invoke-Guest "systemd-run --unit=$Unit --collect $setenv /bin/bash -c 'bash $GuestDir/bench/run_all.sh >> $GuestDir/run.log 2>&1'"
    Write-Ok "Pomiar uruchomiony na VM ($EnvList); postep: .\lab.ps1 progress (koniec = linia KONIEC)"
}

switch ($Verb) {
    'status' {
        Write-Host "VM ${VmName}: $(Get-VmState)"
        Write-Host "Dzialajace VM / running: $((& $VBox list runningvms) -join ', ')"
        if ((Get-VmState) -eq 'running') {
            & ssh @sshOpts "root@$VmIp" "uptime; for v in 18 19; do echo postgresql-`$v: `$(systemctl is-active postgresql-`$v 2>/dev/null); done; systemctl is-active $Unit 2>/dev/null | sed 's/^/pomiar: /'" 2>$null
        }
    }

    'start' {
        $running = @(& $VBox list runningvms | Where-Object { $_ -notmatch "^`"$VmName`"" })
        if ($running.Count -gt 0) {
            Write-Warn "Inne dzialajace VM: $($running -join ', ') — zaklocaja pomiar."
            if (-not $Force) { throw 'Zatrzymaj je albo uruchom z -Force / stop them or use -Force.' }
        }
        if ((Get-VmState) -ne 'running') {
            & $VBox startvm $VmName --type headless
            if ($LASTEXITCODE -ne 0) { throw "startvm exit $LASTEXITCODE" }
        }
        Wait-Ssh
        Write-Ok "VM $VmName dziala, SSH odpowiada"
        $ctl = (& $VBox showvminfo $VmName --machinereadable) | Select-String '^storagecontrollername\d+=' | ForEach-Object { $_.Line }
        Write-Host "Kontrolery / controllers: $($ctl -join '; ')"
    }

    'stop' {
        $busy = & ssh @sshOpts "root@$VmIp" "systemctl is-active $Unit 2>/dev/null" 2>$null
        if ($busy -eq 'active' -and -not $Force) { throw 'Trwa pomiar — stop tylko z -Force.' }
        & $VBox controlvm $VmName acpipowerbutton
        Write-Ok "Wyslano ACPI shutdown do $VmName"
    }

    'preflight' {
        $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
        $out = Join-Path $RepoRoot "results\preflight_$ts.txt"
        New-Item -ItemType Directory -Force (Join-Path $RepoRoot 'results') | Out-Null
        $info = & $VBox showvminfo $VmName --machinereadable
        $hdr = @(
            "# Karta srodowiska / environment card — $(Get-Date -Format 'yyyy-MM-dd HH:mm')",
            '## Host',
            "VirtualBox: $(& $VBox --version)",
            "Dzialajace VM: $((& $VBox list runningvms) -join ', ')",
            "Kontrolery i dyski VM: $(($info | Select-String '^(storagecontroller(name|type)\d+|\"(SATA|NVMe)-\d+-\d+\")=' | ForEach-Object { $_.Line }) -join '; ')"
        ) -join "`n"
        $guest = Get-Content -Raw (Join-Path $RepoRoot 'guest\preflight.sh') | & ssh @sshOpts "root@$VmIp" "tr -d '\r' | bash -s"
        Set-Content -Encoding utf8NoBOM -Path $out -Value ($hdr + "`n" + ($guest -join "`n"))
        Get-Content $out
        Write-Ok "Zapisano / saved: $out"
    }

    'install' {
        $prefix = if ($DryRun) { 'DRY_RUN=1 ' } else { '' }
        Write-Step "INSTALL PG19 na $VmName $(if ($DryRun) { '(dry-run)' })"
        Invoke-GuestScript 'guest\install_pg19.sh' $prefix
    }

    'push' {
        Invoke-Guest "mkdir -p $GuestDir/results && chmod 755 /root $GuestDir"
        & scp @sshOpts -r -q (Join-Path $RepoRoot 'bench') (Join-Path $RepoRoot 'sql') "root@${VmIp}:$GuestDir/"
        if ($LASTEXITCODE -ne 0) { throw "scp exit $LASTEXITCODE" }
        Invoke-Guest "sed -i 's/\r$//' $GuestDir/bench/* $GuestDir/sql/*; chmod -R a+rX,go-w $GuestDir; bash -n $GuestDir/bench/*.sh && echo 'skladnia OK'"
        Write-Ok "Skrypty na VM: $GuestDir/{bench,sql}"
    }

    'trial' {
        if ($DryRun) { Invoke-Guest "cd /tmp && DRY_RUN=1 TRIAL=1 SUITE=$Suite bash $GuestDir/bench/run_all.sh"; break }
        Start-GuestRun "SUITE=$Suite TRIAL=1"
    }

    'run' {
        if ($DryRun) { Invoke-Guest "cd /tmp && DRY_RUN=1 SUITE=$Suite RUNS_R=$RunsR RUNS_F=$RunsF bash $GuestDir/bench/run_all.sh"; break }
        Start-GuestRun "SUITE=$Suite RUNS_R=$RunsR RUNS_F=$RunsF $ExtraEnv"
    }

    'progress' {
        & ssh @sshOpts "root@$VmIp" "systemctl is-active $Unit 2>/dev/null | sed 's/^/pomiar: /'; tail -n 25 $GuestDir/run.log"
    }

    'fetch' {
        $dst = Join-Path $RepoRoot 'results'
        New-Item -ItemType Directory -Force $dst | Out-Null
        & scp @sshOpts -r -q "root@${VmIp}:$GuestDir/results/*" $dst
        & scp @sshOpts -q "root@${VmIp}:$GuestDir/run.log" (Join-Path $dst 'run.log')
        Get-ChildItem $dst | Format-Table Name, Length, LastWriteTime -AutoSize
    }

    'ssh' { & ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -i $KeyPath "root@$VmIp" }
}
