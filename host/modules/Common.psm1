# ==============================================================================
# Tytul:        Common.psm1
# Opis:         Wspolne funkcje pomocnicze: logger z poziomami, kolorowe output,
#               Assert-Elevated dla operacji wymagajacych admina, helper IO.
# Description [EN]: Common helpers: leveled logger, colored output,
#               Assert-Elevated for operations requiring admin, IO helpers.
#
# Autor:        KCB Kris
# Data:         2026-05-02
# Wersja:       1.0
# <repo>:       <repo>
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - PowerShell 5.1+
# Requirements [EN]: - PowerShell 5.1+
#
# Uzycie [PL]:       Import-Module .\host\modules\Common.psm1
#                    Write-Log -Level Info -Message 'hello'
# Usage [EN]:        Import-Module .\host\modules\Common.psm1
#                    Write-Log -Level Info -Message 'hello'
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Log levels (lower = more verbose)
$script:LogLevels = @{ Debug = 0; Info = 1; Warn = 2; Error = 3 }
$script:CurrentLogLevel = 1   # default Info

# ANSI-friendly color names mapped to PowerShell ConsoleColor
$script:LevelColors = @{
    Debug = 'DarkGray'
    Info  = 'Cyan'
    Warn  = 'Yellow'
    Error = 'Red'
}

function Set-LogLevel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
        [string]$Level
    )
    $script:CurrentLogLevel = $script:LogLevels[$Level]
}

function Write-Log {
    [CmdletBinding()]
    param(
        [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
        [string]$Level = 'Info',

        [Parameter(Mandatory, Position = 0)]
        [string]$Message,

        [string]$Tag = ''
    )

    if ($script:LogLevels[$Level] -lt $script:CurrentLogLevel) { return }

    $ts = Get-Date -Format 'HH:mm:ss'
    $color = $script:LevelColors[$Level]
    $prefix = if ($Tag) { "[$Tag] " } else { '' }
    Write-Host ("{0} [{1,-5}] {2}{3}" -f $ts, $Level.ToUpper(), $prefix, $Message) -ForegroundColor $color
}

function Write-Step {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ''
    Write-Host ('==> ' + $Message) -ForegroundColor Green
    Write-Host ('-' * ([Math]::Min(80, $Message.Length + 4))) -ForegroundColor DarkGreen
}

function Write-Ok {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ('  OK  ' + $Message) -ForegroundColor Green
}

function Write-Fail {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host (' FAIL ' + $Message) -ForegroundColor Red
}

function Write-Skip {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host (' SKIP ' + $Message) -ForegroundColor DarkGray
}

# ------------------------------------------------------------------------------
# Elevation check -- used by HostDns (NRPT requires admin) and a few other ops
# ------------------------------------------------------------------------------
function Assert-Elevated {
    [CmdletBinding()]
    param()

    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($current)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        throw 'This action requires elevated PowerShell. Right-click PowerShell > Run as administrator.'
    }
}

function Test-Elevated {
    [CmdletBinding()]
    param()
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($current)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ------------------------------------------------------------------------------
# UTF-8 (no BOM) writer -- never use Set-Content -Encoding UTF8 in PS5.1
# ------------------------------------------------------------------------------
function Write-Utf8NoBom {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $enc = [System.Text.UTF8Encoding]::new($false)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Read-Utf8NoBom {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $enc = [System.Text.UTF8Encoding]::new($false)
    return [System.IO.File]::ReadAllText($Path, $enc)
}

# ------------------------------------------------------------------------------
# Repo configuration loader
# ------------------------------------------------------------------------------
function Get-LabConfig {
    [CmdletBinding()]
    param(
        [string]$RepoRoot
    )
    if (-not $RepoRoot) {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }
    $real = Join-Path $RepoRoot 'lab.config.psd1'
    $sample = Join-Path $RepoRoot 'lab.config.example.psd1'
    $path = if (Test-Path $real) { $real } else { $sample }
    if (-not (Test-Path $path)) {
        throw "No lab config found. Expected: $real or $sample"
    }
    # Uwaga: NIE uzywamy Import-PowerShellDataFile, bo odrzuca wyrazenia dynamiczne
    # ($env:LOCALAPPDATA, $env:USERPROFILE) uzywane w sciezkach configu. Ladujemy
    # plik jako scriptblock, dzieki czemu $env: sie rozwija. Plik jest lokalny i
    # zaufany (tworzony przez uzytkownika z lab.config.example.psd1).
    # Note: we avoid Import-PowerShellDataFile because it rejects dynamic expressions
    # ($env:*) used in config paths. We load the .psd1 as a scriptblock so $env:
    # expands; the file is local and user-owned (trusted).
    $raw = Get-Content -Raw -LiteralPath $path
    $cfg = & ([scriptblock]::Create($raw))
    $cfg | Add-Member -NotePropertyName _SourcePath -NotePropertyValue $path -Force
    return $cfg
}

# ------------------------------------------------------------------------------
# Path helpers
# ------------------------------------------------------------------------------
function Get-RepoRoot {
    return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

# ------------------------------------------------------------------------------
# VBoxManage locator
# ------------------------------------------------------------------------------
function Get-VBoxManagePath {
    [CmdletBinding()]
    param()
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Oracle\VirtualBox\VBoxManage.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    $cmd = Get-Command 'VBoxManage.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

Export-ModuleMember -Function `
    'Set-LogLevel', 'Write-Log', 'Write-Step', 'Write-Ok', 'Write-Fail', 'Write-Skip', `
    'Assert-Elevated', 'Test-Elevated', `
    'Write-Utf8NoBom', 'Read-Utf8NoBom', `
    'Get-LabConfig', 'Get-RepoRoot', 'Get-VBoxManagePath'
