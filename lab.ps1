# ==============================================================================
# Tytul:        lab.ps1
# Opis:         Sterowanie labem pg18-io-methods-lab (jedna VM pgio): plan (podglad
#               bez zmian), build (VM + kickstart wstrzykiwany scancode'ami), provision
#               (dysk danych + PG18), envcard, status, ssh, destroy.
# Description [EN]: Drives pg18-io-methods-lab (single VM pgio): plan (dry-run),
#               build (VM + scancode-injected kickstart), provision (data disk + PG18),
#               envcard, status, ssh, destroy.
#
# Autor:        KCB Kris
# Data:         2026-10-15
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - PowerShell 7, VirtualBox 7.x, Python 3 (serwer KS), OpenSSH,
#                      regula zapory TCP 8000 dla 192.168.56.0/24 (plan pokazuje polecenie)
# Requirements [EN]: - PowerShell 7, VirtualBox 7.x, Python 3 (KS server), OpenSSH,
#                      firewall rule TCP 8000 for 192.168.56.0/24 (plan prints the command)
#
# Uzycie [PL]:       .\lab.ps1 plan | build | provision [-DryRun] | envcard | status | ssh | destroy pgio
# Usage [EN]:        .\lab.ps1 plan | build | provision [-DryRun] | envcard | status | ssh | destroy pgio
# ==============================================================================
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('plan', 'build', 'provision', 'envcard', 'loaddata', 'plans', 'bench', 'fetch', 'status', 'ssh', 'destroy')]
    [string]$Verb = 'plan',
    [Parameter(Position = 1)][string]$Target,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = $PSScriptRoot
# Kolejnosc odwrotna do zaleznosci: moduly importuja sie nawzajem z -Force, co zdejmuje
# wczesniej zaladowane — dlatego bazowe (Common) laduja sie NA KONCU.
# Reverse dependency order: modules re-import each other with -Force, which unloads
# earlier imports — so base modules (Common) load LAST.
foreach ($m in 'BootKickstart', 'KsServer', 'Network', 'VmBuilder', 'Scancode', 'Common') {
    Import-Module (Join-Path $RepoRoot "host\modules\$m.psm1") -Force -DisableNameChecking -Global
}
$cfg = Get-LabConfig -RepoRoot $RepoRoot
$vm = $cfg.Vm
$sshOpts = @('-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL', '-o', 'BatchMode=yes',
             '-o', 'ConnectTimeout=10', '-i', $cfg.Ssh.KeyPath)

# ------------------------------------------------------------------------------
# Kontrole hosta (tylko odczyt) / host checks (read-only)
# ------------------------------------------------------------------------------
function Test-HostReady {
    $ok = $true
    $vbox = Get-VBoxManagePath
    $checks = [ordered]@{}
    $checks['VBoxManage'] = [bool]$vbox
    $checks['ISO istnieje'] = Test-Path $cfg.Iso.Path
    if ($checks['ISO istnieje']) {
        $checks['ISO SHA-256 zgodne'] = ((Get-FileHash $cfg.Iso.Path -Algorithm SHA256).Hash.ToLower() -eq $cfg.Iso.Sha256)
    }
    $checks['Klucz SSH (.pub)'] = Test-Path "$($cfg.Ssh.KeyPath).pub"
    $checks["Host-only $($cfg.Network.HostIp)"] = [bool](Get-LabHostonlyAdapter)
    $checks["VM '$($vm.Name)' jeszcze nie istnieje"] = -not (Test-VmExists -Name $vm.Name)
    $checks["IP $($vm.Ip) wolny (brak ping)"] = -not (Test-Connection $vm.Ip -Count 1 -TimeoutSeconds 1 -Quiet)
    $checks['Port 8000 wolny'] = -not (Get-NetTCPConnection -LocalPort $cfg.KsServer.Port -State Listen -ErrorAction SilentlyContinue)
    # Szukamy przez reguly, nie przez Get-NetFirewallPortFilter: bez admina pelna lista filtrow
    # urywa sie na "Odmowa dostepu" i regula moze w niej nie wystapic (sprawdzone 2026-10-15).
    # Search via rules: without admin the full port-filter list stops at "Access denied".
    $fw = Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True -ErrorAction SilentlyContinue |
          Where-Object { ($_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -contains "$($cfg.KsServer.Port)" }
    $fwOk = [bool]$fw
    $drive = (Get-Item (& $vbox list systemproperties | Select-String 'Default machine folder' |
              ForEach-Object { ($_ -split ':\s+', 2)[1].Trim() })).PSDrive
    $freeGb = [math]::Round($drive.Free / 1GB)
    $checks["Wolne miejsce $($drive.Name): ${freeGb} GB (>= 80)"] = ($freeGb -ge 80)
    $running = @(& $vbox list runningvms)
    $checks["Inne dzialajace VM: $($running.Count)"] = ($running.Count -eq 0)

    foreach ($k in $checks.Keys) {
        if ($checks[$k]) { Write-Ok $k } else { Write-Fail $k; $ok = $false }
    }
    # Zapora = ostrzezenie, nie blokada: na tym hoscie ruch lokalny bywa przepuszczany i bez reguly;
    # jesli instalator nie pobierze kickstartu, dopiero wtedy regula jest potrzebna.
    # Firewall = warning, not a blocker.
    if ($fwOk) { Write-Ok "Zapora: regula TCP $($cfg.KsServer.Port) inbound ($($fw.DisplayName -join ', '))" }
    else {
        Write-Host " WARN Zapora: brak reguly TCP $($cfg.KsServer.Port) — jesli instalator nie pobierze kickstartu:" -ForegroundColor Yellow
        Write-Host "  -> jako administrator / as admin:" -ForegroundColor Yellow
        Write-Host "     New-NetFirewallRule -DisplayName 'pgio-lab-ks-8000' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $($cfg.KsServer.Port) -RemoteAddress 192.168.56.0/24" -ForegroundColor Yellow
    }
    return $ok
}

function Invoke-RenderKs {
    $tmpl = Read-Utf8NoBom -Path (Join-Path $RepoRoot 'kickstart\pgio.ks.tmpl')
    $pub = (Get-Content -Raw "$($cfg.Ssh.KeyPath).pub").Trim()
    $out = $tmpl.Replace('{{IP}}', $vm.Ip).Replace('{{HOSTNAME}}', $vm.Hostname).Replace('{{SSH_PUBKEY}}', $pub)
    $path = Join-Path $RepoRoot 'kickstart\pgio.ks'
    Write-Utf8NoBom -Path $path -Content ($out -replace "`r`n", "`n")
    return $path
}

function Get-KsUrl { "http://$($cfg.KsServer.BindIp):$($cfg.KsServer.Port)/kickstart/pgio.ks" }

switch ($Verb) {
    'plan' {
        Write-Step 'PLAN (dry-run) — nic nie jest tworzone / nothing is created'
        $ready = Test-HostReady
        $ks = Invoke-RenderKs
        Write-Ok "Wyrenderowany kickstart / rendered: $ks"
        $vbox = Get-VBoxManagePath
        Write-Step 'Polecenia, ktore wykona build / commands build will run'
        @(
            "Start-KsServer  -> python host\ks_server.py $RepoRoot $($cfg.KsServer.BindIp) $($cfg.KsServer.Port)",
            "VBoxManage createvm --name $($vm.Name) --ostype RedHat_64 --register",
            "VBoxManage modifyvm $($vm.Name) --memory $($vm.Ram) --cpus $($vm.Cpu) --nic1 hostonly --nic2 nat --boot1 disk --boot2 dvd",
            "VBoxManage createmedium disk <D:\VM\$($vm.Name)\$($vm.Name).vdi> --size $($vm.OsDiskMb)",
            "VBoxManage storagectl $($vm.Name) --name SATA --add sata --portcount 3 --hostiocache off",
            "VBoxManage storageattach ... port 0 = OS vdi (--nonrotational on), port 1 = ISO $($cfg.Iso.Path)",
            "VBoxManage createmedium disk <$($vm.Name)-data.vdi> --size $($vm.DataDiskMb) --variant Fixed ; storageattach port 2 (--nonrotational on)",
            "VBoxManage startvm $($vm.Name) --type gui",
            "keyboardputscancode: Tab + ' inst.ks=$(Get-KsUrl) inst.text ip=$($vm.Ip):::$($cfg.Network.Netmask):$($vm.Hostname):enp0s3:none' + Enter",
            "Wait-Ssh $($vm.Ip):22 (max 30 min) -> Detach ISO -> Stop-KsServer"
        ) | ForEach-Object { Write-Host "  $_" }
        Write-Step 'Nastepnie / then'
        Write-Host '  .\lab.ps1 provision -DryRun   # podglad przygotowania VM'
        Write-Host '  .\lab.ps1 provision           # dysk danych + PostgreSQL 18'
        Write-Host '  .\lab.ps1 envcard             # karta srodowiska -> results\env_card.txt'
        if (-not $ready) { Write-Fail 'Host NIE jest gotowy — popraw pozycje oznaczone powyzej.' } else { Write-Ok 'Host gotowy do build.' }
    }

    'build' {
        Write-Step "BUILD VM $($vm.Name)"
        if (-not (Test-HostReady)) { throw 'Host nie jest gotowy — uruchom .\lab.ps1 plan i popraw.' }
        Invoke-RenderKs | Out-Null
        $hostonly = Initialize-LabNetwork -HostIp $cfg.Network.HostIp -Netmask $cfg.Network.Netmask
        Start-KsServer -RepoRoot $RepoRoot -BindIp $cfg.KsServer.BindIp -Port $cfg.KsServer.Port | Out-Null
        try {
            New-LabVm -Name $vm.Name -Ram $vm.Ram -Cpu $vm.Cpu -HostonlyAdapter $hostonly -IsoPath $cfg.Iso.Path `
                -DiskMb $vm.OsDiskMb -DataDiskMb $vm.DataDiskMb
            Start-VmWithKickstart -VmName $vm.Name -KsUrl (Get-KsUrl) -VmIp $vm.Ip -VmHostname $vm.Hostname `
                -Netmask $cfg.Network.Netmask
            Wait-Ssh -IpAddress $vm.Ip -TimeoutMinutes 30
            Detach-LabVmIso -Name $vm.Name
        } finally {
            Stop-KsServer
        }
        & ssh @sshOpts "root@$($vm.Ip)" 'hostname; cat /etc/rocky-release; lsblk -o NAME,SIZE,TYPE,MOUNTPOINT'
        Write-Ok 'BUILD gotowy. Dalej: .\lab.ps1 provision -DryRun'
    }

    'provision' {
        $script = Join-Path $RepoRoot 'guest\provision.sh'
        $prefix = if ($DryRun) { 'DRY_RUN=1 ' } else { '' }
        Write-Step "PROVISION $($vm.Name) $(if ($DryRun) { '(dry-run)' })"
        # PowerShell dokleja CRLF na koncu tekstu przekazywanego do ssh -> "command not found"
        # (exit 127, sprawdzone 2026-10-15); usuwamy CR po stronie VM. / PS appends CRLF when piping to ssh.
        Get-Content -Raw $script | & ssh @sshOpts "root@$($vm.Ip)" "tr -d '\r' | ${prefix}bash -s"
        if ($LASTEXITCODE -ne 0) { throw "provision.sh exit $LASTEXITCODE" }
    }

    'envcard' {
        $out = Join-Path $RepoRoot 'results\env_card.txt'
        $vbox = Get-VBoxManagePath
        $hdr = @(
            "# Karta srodowiska / environment card — $(Get-Date -Format 'yyyy-MM-dd HH:mm')",
            "## Host",
            "VirtualBox: $(& $vbox --version)",
            "Dysk hosta: $((Get-PhysicalDisk | Where-Object DeviceId -eq ((Get-Partition -DriveLetter D).DiskNumber)).FriendlyName)",
            "Dzialajace VM: $((& $vbox list runningvms) -join ', ')",
            # showvminfo nie pokazuje host I/O cache — czytamy z pliku .vbox / not in showvminfo, read .vbox
            "SATA: $((Select-String -Path (Join-Path (Split-Path ((& $vbox showvminfo $vm.Name --machinereadable | Select-String '^CfgFile=').Line -replace '^CfgFile="|"$','')) "$($vm.Name).vbox") -Pattern '<StorageController ' | ForEach-Object { if ($_.Line -match 'useHostIOCache="(\w+)"') { "useHostIOCache=$($Matches[1])" } }) -join '; ')"
        ) -join "`n"
        $guest = Get-Content -Raw (Join-Path $RepoRoot 'guest\env_card.sh') | & ssh @sshOpts "root@$($vm.Ip)" "tr -d '\r' | bash -s"
        Write-Utf8NoBom -Path $out -Content ($hdr + "`n" + ($guest -join "`n") + "`n")
        Get-Content $out
        Write-Ok "Zapisano / saved: $out"
    }

    'loaddata' {
        # Kopiuje sql/ + bench/ na VM i uruchamia generator w tle (nohup) — przezyje rozlaczenie SSH.
        # Copies sql/ + bench/ to the VM and runs the generator in the background (nohup).
        & ssh @sshOpts "root@$($vm.Ip)" 'mkdir -p /root/pgio && chmod 755 /root /root/pgio'
        & scp @sshOpts -r -q (Join-Path $RepoRoot 'sql') (Join-Path $RepoRoot 'bench') "root@$($vm.Ip):/root/pgio/"
        & ssh @sshOpts "root@$($vm.Ip)" "sed -i 's/\r$//' /root/pgio/sql/*.sql /root/pgio/bench/*; chmod -R a+rX /root/pgio; cd /tmp && nohup sudo -u postgres /usr/pgsql-18/bin/psql -X -f /root/pgio/sql/01_create_test_data.sql < /dev/null > /root/pgio/load.log 2>&1 &"
        Write-Ok 'Generator danych uruchomiony w tle; log: /root/pgio/load.log (koniec = LOAD OK)'
    }

    'plans' {
        & scp @sshOpts -r -q (Join-Path $RepoRoot 'bench') "root@$($vm.Ip):/root/pgio/"
        & ssh @sshOpts "root@$($vm.Ip)" "sed -i 's/\r$//' /root/pgio/bench/*; bash /root/pgio/bench/plan_check.sh /root/pgio/bench/tests.conf"
    }

    'bench' {
        # Pomiar w tle na VM (nohup); $Target = liczba serii (domyslnie 7). / Background run; Target = series.
        $runs = if ($Target) { [int]$Target } else { 7 }
        & scp @sshOpts -r -q (Join-Path $RepoRoot 'bench') "root@$($vm.Ip):/root/pgio/"
        & ssh @sshOpts "root@$($vm.Ip)" "sed -i 's/\r$//' /root/pgio/bench/*; cd /tmp && RUNS=$runs nohup bash /root/pgio/bench/run_bench.sh < /dev/null > /root/pgio/bench_run.log 2>&1 &"
        Write-Ok "Pomiar uruchomiony ($runs serii); log: /root/pgio/bench_run.log, wyniki: /root/pgio/results/"
    }

    'fetch' {
        # Pobranie wynikow z VM do results\ / pull results from the VM
        & scp @sshOpts -r -q "root@$($vm.Ip):/root/pgio/results/*" (Join-Path $RepoRoot 'results')
        & scp @sshOpts -q "root@$($vm.Ip):/root/pgio/bench_run.log" (Join-Path $RepoRoot 'results\bench_run.log')
        Get-ChildItem (Join-Path $RepoRoot 'results') | Format-Table Name, Length, LastWriteTime -AutoSize
    }

    'status' {
        Write-Host "VM $($vm.Name): $(Get-VmState -Name $vm.Name)"
        & ssh @sshOpts "root@$($vm.Ip)" 'uptime; systemctl is-active postgresql-18 2>/dev/null; findmnt -n /pgdata 2>/dev/null' 2>$null
    }

    'ssh' { & ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -i $cfg.Ssh.KeyPath "root@$($vm.Ip)" }

    'destroy' {
        if ($Target -ne $vm.Name) { throw "Potwierdz nazwa VM: .\lab.ps1 destroy $($vm.Name)" }
        Remove-LabVm -Name $vm.Name -Force
    }
}
