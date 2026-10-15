# ==============================================================================
# Tytul:        KsServer.psm1
# Opis:         Uruchamia serwer HTTP kickstart przez Start-Process Python
#               (host/ks_server.py) -- serwuje TYLKO kickstart/ + guest/. Raw socket
#               Pythona NIE dotyka http.sys, wiec brak URL ACL, osieroconych portow
#               i exclusion (problemy ktore mial wczesniejszy System.Net.HttpListener).
# Description [EN]: Starts the kickstart HTTP server via Start-Process Python
#               (host/ks_server.py) -- serves ONLY kickstart/ + guest/. Python's raw
#               socket does NOT touch http.sys, so no URL ACL, orphaned ports or
#               port exclusions (issues the old System.Net.HttpListener had).
#
# Autor:        KCB Kris
# Data:         2026-05-30
# Wersja:       2.0
# <repo>:       <repo>
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - PowerShell 5.1+, Python 3.8+ na hoscie, IP 192.168.56.1 na vboxnet0
#                    - port 8000 dopuszczony w zaporze dla 192.168.56.0/24
# Requirements [EN]: - PowerShell 5.1+, Python 3.8+ on host, IP 192.168.56.1 on vboxnet0
#                    - TCP 8000 allowed in firewall for 192.168.56.0/24
#
# Uzycie [PL]:       Start-KsServer -RepoRoot <repo> -BindIp 192.168.56.1 -Port 8000
#                    Stop-KsServer
# Usage [EN]:        Start-KsServer -RepoRoot <repo> -BindIp 192.168.56.1 -Port 8000
#                    Stop-KsServer
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force -DisableNameChecking

$script:PidFile = Join-Path $env:TEMP 'pgio-lab-ks.pid'

function Find-PythonExe {
    [CmdletBinding()]
    param()
    foreach ($name in @('python.exe', 'python3.exe', 'py.exe')) {
        $c = Get-Command $name -ErrorAction SilentlyContinue
        if ($c) {
            if ($name -eq 'py.exe') { return @{ Exe = $c.Source; Prefix = @('-3') } }
            return @{ Exe = $c.Source; Prefix = @() }
        }
    }
    $known = 'C:\Program Files\Python312\python.exe'
    if (Test-Path $known) { return @{ Exe = $known; Prefix = @() } }
    throw 'Python not found (python/python3/py). Install Python 3.x or add it to PATH.'
}

function Start-KsServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$BindIp = '192.168.56.1',
        [int]$Port = 8000
    )

    if (-not (Test-Path $RepoRoot)) {
        throw "RepoRoot not found: $RepoRoot"
    }

    # Idempotency: reuse a live server from a previous call in THIS session (PID file).
    # Weryfikujemy command line, by nie trafic na recyklowany PID innego procesu.
    if (Test-Path $script:PidFile) {
        $oldPid = Get-Content $script:PidFile -ErrorAction SilentlyContinue
        if ($oldPid) {
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$oldPid" -ErrorAction SilentlyContinue
            if ($p -and $p.CommandLine -match 'ks_server\.py') {
                Write-Log -Level Info -Message "KsServer already running as PID $oldPid"
                return (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)
            }
        }
        Remove-Item $script:PidFile -Force -ErrorAction SilentlyContinue
    }

    # Zniwiarz: ubij osierocone instancje ks_server.py z poprzednich (przerwanych) buildow.
    # Python zwalnia socket natychmiast po smierci procesu (brak http.sys), wiec to wystarcza --
    # zaden wiszacy listener nie zostaje nawet po Ctrl+C / zamknieciu okna.
    # Reaper: kill orphaned ks_server.py from previous (aborted) builds before starting fresh.
    Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='python3.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'ks_server\.py' } |
        ForEach-Object {
            Write-Log -Level Warn -Message "Reaping stale ks_server.py (PID $($_.ProcessId))"
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }

    $py = Find-PythonExe
    $serverScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\ks_server.py'))
    if (-not (Test-Path $serverScript)) { throw "ks_server.py not found: $serverScript" }

    Write-Step "Starting kickstart HTTP server (Python) on http://${BindIp}:${Port}/ (RepoRoot=$RepoRoot)"

    $logOut = Join-Path $env:TEMP 'pgio-lab-ks.out.log'
    $logErr = Join-Path $env:TEMP 'pgio-lab-ks.err.log'

    # Quote path-like args (spaces-safe); BindIp/Port are simple tokens
    $argLine = (@($py.Prefix) + @(
        ('"{0}"' -f $serverScript),
        ('"{0}"' -f $RepoRoot),
        $BindIp,
        "$Port"
    )) -join ' '

    $proc = Start-Process -FilePath $py.Exe -ArgumentList $argLine `
        -WorkingDirectory $RepoRoot -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $logOut -RedirectStandardError $logErr

    $proc.Id | Out-File -FilePath $script:PidFile -Encoding ascii -Force

    # Wait until it actually answers (or dies)
    $deadline = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $deadline) {
        if ($proc.HasExited) {
            $err = (Get-Content $logErr -ErrorAction SilentlyContinue | Out-String)
            throw "KsServer (python) exited immediately (code $($proc.ExitCode)). Log: $err"
        }
        if (Test-KsServer -BindIp $BindIp -Port $Port) {
            Write-Ok "KsServer running as PID $($proc.Id) (access log: $logErr)"
            return $proc
        }
        Start-Sleep -Milliseconds 500
    }
    throw "KsServer did not answer on http://${BindIp}:${Port}/ within 12s. Check firewall (TCP 8000 for 192.168.56.0/24) and $logErr"
}

function Stop-KsServer {
    [CmdletBinding()]
    param()
    if (Test-Path $script:PidFile) {
        $id = Get-Content $script:PidFile -ErrorAction SilentlyContinue
        if ($id) {
            $p = Get-Process -Id $id -ErrorAction SilentlyContinue
            if ($p) {
                Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
                Write-Ok "Stopped KsServer PID $id"
            }
        }
        Remove-Item $script:PidFile -Force -ErrorAction SilentlyContinue
    } else {
        Write-Log -Level Info -Message 'KsServer not running (no PID file).'
    }
}

function Test-KsServer {
    [CmdletBinding()]
    param(
        [string]$BindIp = '192.168.56.1',
        [int]$Port = 8000
    )
    try {
        $r = Invoke-WebRequest -Uri "http://${BindIp}:${Port}/kickstart/health.txt" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        return ($r.StatusCode -eq 200)
    } catch {
        return $false
    }
}

Export-ModuleMember -Function 'Start-KsServer', 'Stop-KsServer', 'Test-KsServer', 'Find-PythonExe'
