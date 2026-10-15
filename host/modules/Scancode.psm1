# ==============================================================================
# Tytul:        Scancode.psm1
# Opis:         Mapper ASCII -> US PS/2 scancode pairs (press + release).
#               Send-VmString wysyla string znak po znaku do VBoxManage controlvm
#               keyboardputscancode, chunked po N znakow z pauza miedzy chunkami.
#               Krytyczny komponent -- testy Pester musza byc zielone przed uzyciem.
# Description [EN]: ASCII -> US PS/2 scancode pair (press + release) mapper.
#               Send-VmString sends a string character-by-character via
#               VBoxManage controlvm keyboardputscancode, chunked with pauses.
#               Critical component -- Pester tests MUST be green before use.
#
# Autor:        KCB Kris
# Data:         2026-05-02
# Wersja:       1.0
# <repo>:       <repo>
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - VirtualBox 7.0+ (VBoxManage.exe), uruchamiana VM w stanie
#                      pozwalajacym na keyboardputscancode (np. ISOLINUX boot menu)
# Requirements [EN]: - VirtualBox 7.0+ (VBoxManage.exe), VM in a state that
#                      accepts keyboardputscancode (e.g. ISOLINUX boot menu)
#
# Uzycie [PL]:       Send-VmString -Vm pg1 -Text 'inst.ks=http://...'
#                    Send-VmEnter -Vm pg1
# Usage [EN]:        Send-VmString -Vm pg1 -Text 'inst.ks=http://...'
#                    Send-VmEnter -Vm pg1
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force -DisableNameChecking

# ------------------------------------------------------------------------------
# US-keyboard scancode table.
# Each entry: char -> @{ Press = 'XX' [optional 2nd byte for shift]; Release = 'YY' [...] }
# Press codes are the make codes; release = make | 0x80.
# ------------------------------------------------------------------------------

# Base codes for unshifted characters (US layout)
$script:BaseCodes = @{
    # Letters a-z (set 1, US)
    'a' = '1e'; 'b' = '30'; 'c' = '2e'; 'd' = '20'; 'e' = '12'; 'f' = '21'
    'g' = '22'; 'h' = '23'; 'i' = '17'; 'j' = '24'; 'k' = '25'; 'l' = '26'
    'm' = '32'; 'n' = '31'; 'o' = '18'; 'p' = '19'; 'q' = '10'; 'r' = '13'
    's' = '1f'; 't' = '14'; 'u' = '16'; 'v' = '2f'; 'w' = '11'; 'x' = '2d'
    'y' = '15'; 'z' = '2c'

    # Digits 0-9 (top row)
    '1' = '02'; '2' = '03'; '3' = '04'; '4' = '05'; '5' = '06'
    '6' = '07'; '7' = '08'; '8' = '09'; '9' = '0a'; '0' = '0b'

    # Punctuation (unshifted)
    '-' = '0c'; '=' = '0d'
    '[' = '1a'; ']' = '1b'
    ';' = '27'; "'" = '28'
    '`' = '29'; '\' = '2b'
    ',' = '33'; '.' = '34'; '/' = '35'

    # Whitespace
    ' ' = '39'   # space
}

# Characters requiring Shift (Shift = 0x2a make / 0xaa release)
$script:ShiftMap = @{
    '!' = '02'; '@' = '03'; '#' = '04'; '$' = '05'; '%' = '06'
    '^' = '07'; '&' = '08'; '*' = '09'; '(' = '0a'; ')' = '0b'
    '_' = '0c'; '+' = '0d'
    '{' = '1a'; '}' = '1b'
    ':' = '27'; '"' = '28'
    '~' = '29'; '|' = '2b'
    '<' = '33'; '>' = '34'; '?' = '35'
}

# Special key names
$script:SpecialKeys = @{
    'Enter'     = @{ Press = '1c'      ; Release = '9c'      }
    'Tab'       = @{ Press = '0f'      ; Release = '8f'      }
    'Esc'       = @{ Press = '01'      ; Release = '81'      }
    'Backspace' = @{ Press = '0e'      ; Release = '8e'      }
    'Space'     = @{ Press = '39'      ; Release = 'b9'      }
    'CtrlX'     = @{ Press = '1d 2d'   ; Release = 'ad 9d'   }   # Ctrl + X
}

function Convert-CharToScancode {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Char)

    if ($Char.Length -ne 1) {
        throw "Convert-CharToScancode expects exactly one character, got '$Char' (length $($Char.Length))"
    }

    $c = $Char

    # Uppercase letter -> shift + lowercase code
    if ($c -cmatch '^[A-Z]$') {
        $lower = $c.ToLower()
        $base = $script:BaseCodes[$lower]
        $release = '{0:x2}' -f ([int]"0x$base" + 0x80)
        return @{
            Press   = "2a $base"
            Release = "$release aa"
        }
    }

    # Shifted punctuation
    if ($script:ShiftMap.ContainsKey($c)) {
        $base = $script:ShiftMap[$c]
        $release = '{0:x2}' -f ([int]"0x$base" + 0x80)
        return @{
            Press   = "2a $base"
            Release = "$release aa"
        }
    }

    # Unshifted (lowercase, digit, simple punctuation, space)
    if ($script:BaseCodes.ContainsKey($c)) {
        $base = $script:BaseCodes[$c]
        $release = '{0:x2}' -f ([int]"0x$base" + 0x80)
        return @{
            Press   = $base
            Release = $release
        }
    }

    throw "No scancode mapping for character '$c' (0x$([int][char]$c | ForEach-Object {'{0:x4}' -f $_}))"
}

function ConvertTo-ScancodeSequence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($ch in $Text.ToCharArray()) {
        $sc = Convert-CharToScancode -Char ([string]$ch)
        $parts.Add($sc.Press)
        $parts.Add($sc.Release)
    }
    return ($parts -join ' ')
}

function ConvertTo-SpecialKeyScancode {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key)

    if (-not $script:SpecialKeys.ContainsKey($Key)) {
        throw "Unknown special key '$Key'. Known: $($script:SpecialKeys.Keys -join ', ')"
    }
    $entry = $script:SpecialKeys[$Key]
    return "$($entry.Press) $($entry.Release)"
}

# ------------------------------------------------------------------------------
# VBoxManage interaction
# ------------------------------------------------------------------------------
function Send-VmString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Vm,
        [Parameter(Mandatory)][string]$Text,
        [int]$ChunkSize = 30,
        [int]$ChunkDelayMs = 50
    )

    $vbox = Get-VBoxManagePath
    if (-not $vbox) { throw 'VBoxManage.exe not found.' }

    $idx = 0
    while ($idx -lt $Text.Length) {
        $end = [Math]::Min($idx + $ChunkSize, $Text.Length)
        $chunk = $Text.Substring($idx, $end - $idx)
        $hex = ConvertTo-ScancodeSequence -Text $chunk
        $hexBytes = $hex.Split(' ')
        & $vbox controlvm $Vm keyboardputscancode @hexBytes | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "VBoxManage controlvm $Vm keyboardputscancode failed (exit $LASTEXITCODE) on chunk '$chunk'"
        }
        Start-Sleep -Milliseconds $ChunkDelayMs
        $idx = $end
    }
}

function Send-VmKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Vm,
        [Parameter(Mandatory)][ValidateSet('Enter', 'Tab', 'Esc', 'Backspace', 'Space', 'CtrlX')][string]$Key
    )
    $vbox = Get-VBoxManagePath
    if (-not $vbox) { throw 'VBoxManage.exe not found.' }
    $hex = ConvertTo-SpecialKeyScancode -Key $Key
    & $vbox controlvm $Vm keyboardputscancode @($hex.Split(' ')) | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "VBoxManage controlvm $Vm keyboardputscancode failed for key $Key (exit $LASTEXITCODE)"
    }
}

# Aliases
function Send-VmEnter     { param([string]$Vm) Send-VmKey -Vm $Vm -Key 'Enter' }
function Send-VmTab       { param([string]$Vm) Send-VmKey -Vm $Vm -Key 'Tab' }
function Send-VmEsc       { param([string]$Vm) Send-VmKey -Vm $Vm -Key 'Esc' }
function Send-VmBackspace { param([string]$Vm) Send-VmKey -Vm $Vm -Key 'Backspace' }
function Send-VmCtrlX     { param([string]$Vm) Send-VmKey -Vm $Vm -Key 'CtrlX' }

Export-ModuleMember -Function `
    'Convert-CharToScancode', 'ConvertTo-ScancodeSequence', 'ConvertTo-SpecialKeyScancode', `
    'Send-VmString', 'Send-VmKey', `
    'Send-VmEnter', 'Send-VmTab', 'Send-VmEsc', 'Send-VmBackspace', 'Send-VmCtrlX'
