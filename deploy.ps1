# deploy.ps1 - Despliega los plugins HestiaCP (watchdog + staging) en un servidor
# desde Windows usando PuTTY (plink). Transferencia por tar+base64 sobre plink
# (NO usa pscp/SFTP, que muchos servidores tienen deshabilitado). Idempotente:
# preserva conf/ y state/, re-aplica la integracion de UI (menu + botones) y deja
# los kill switches activados por seguridad.
#
# Uso:  abre PowerShell en esta carpeta, rellena $Server/$User/$Pass y ejecuta:
#         .\deploy.ps1
#       (si la politica lo bloquea:  powershell -ExecutionPolicy Bypass -File .\deploy.ps1)
#
# Requisitos: PuTTY instalado (winget install --id PuTTY.PuTTY), tar.exe (incluido
# en Windows 10/11), y un servidor con HestiaCP accesible por SSH como root.

# ===========================================================================
# CONFIGURACION  (EDITA ESTOS VALORES)
# ===========================================================================
$Server = '00.00.00.00'
$User = 'root'
$Pass = 'wewqeqwe12132312312'          # <-- contrasena root del servidor destino
$Port = '22'
$RemoteBase = '/usr/local/hestia/plugins'
$EnableUI = $true                      # publica symlinks de UI bajo /usr/local/hestia/web/
$RunInstall = $true                      # ejecuta install.sh de cada plugin (cron, menu, botones)
# ===========================================================================

$ErrorActionPreference = 'Stop'
$LocalDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- Localiza plink --------------------------------------------------------
function Resolve-Tool($name) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($d in @((Join-Path $env:ProgramFiles 'PuTTY'), (Join-Path ${env:ProgramFiles(x86)} 'PuTTY'), (Join-Path $env:LOCALAPPDATA 'Programs\PuTTY'))) {
        $p = Join-Path $d $name
        if (Test-Path $p) { return $p }
    }
    throw "No se encontro $name. Instala PuTTY:  winget install --id PuTTY.PuTTY -e"
}
$Plink = Resolve-Tool 'plink.exe'
$Tar = (Get-Command tar.exe -ErrorAction SilentlyContinue).Source
if (-not $Tar) { throw "No se encontro tar.exe (incluido en Windows 10/11)." }

if ([string]::IsNullOrWhiteSpace($Pass)) { throw "Edita deploy.ps1 y pon la contrasena en `$Pass." }
foreach ($p in 'watchdog', 'staging') {
    if (-not (Test-Path (Join-Path $LocalDir $p))) { throw "No se encuentra la carpeta '$p' junto a deploy.ps1." }
}
$Target = "$User@$Server"

# --- Ejecuta un script bash remoto (contenido) via plink -m fichero (LF) ----
function Invoke-RemoteScript([string]$bash) {
    $tmp = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllText($tmp, ($bash -replace "`r`n", "`n"))
    try {
        & $Plink -ssh -P $Port -pw $Pass -batch $Target -m $tmp
        if ($LASTEXITCODE -ne 0) { throw "plink fallo (exit $LASTEXITCODE)." }
    }
    finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

# --- Transferencia de un .tgz por STDIN (sin base64 incrustado) + extraccion --
# El binario se transmite por la entrada estandar de plink en una sola conexion.
# NO se incrusta el base64 en la linea de comando: el exec de SSH ejecuta
# 'bash -c "<comando>"' y un unico argumento esta limitado a MAX_ARG_STRLEN
# (~128 KB en Linux); un .tgz de pocos cientos de KB lo supera y produce
# "Argument list too long". El streaming por stdin no tiene ese limite.
function Send-Tree {
    $tgz = Join-Path $env:TEMP 'hestia-deploy.tgz'
    if (Test-Path $tgz) { Remove-Item $tgz -Force }
    & $Tar -czf $tgz -C $LocalDir watchdog staging
    if ($LASTEXITCODE -ne 0) { throw "tar fallo al empaquetar." }
    # Prepara el destino remoto (comando corto, sin payload).
    Invoke-RemoteScript "rm -rf /tmp/hestia-deploy; mkdir -p /tmp/hestia-deploy"
    # Sube y extrae: stdin (el .tgz) -> 'tar xzf -' en el servidor.
    $p = Start-Process -FilePath $Plink `
        -ArgumentList @('-ssh', '-P', $Port, '-pw', $Pass, '-batch', $Target, 'tar xzf - -C /tmp/hestia-deploy') `
        -RedirectStandardInput $tgz -NoNewWindow -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Subida/extraccion del .tgz por stdin fallo (exit $($p.ExitCode))." }
    # Verificacion (cuenta de ficheros extraidos).
    Invoke-RemoteScript "echo UPLOAD_OK; find /tmp/hestia-deploy -type f | wc -l"
    Remove-Item $tgz -Force -ErrorAction SilentlyContinue
}

Write-Host "==> [0/6] Cacheando host key (primera conexion) ..." -ForegroundColor Cyan
"y`n" | & $Plink -ssh -P $Port -pw $Pass $Target "echo HOSTKEY_OK" 2>$null | Out-Null

Write-Host "==> [1/6] Verificando HestiaCP en $Server ..." -ForegroundColor Cyan
Invoke-RemoteScript "echo conexion-OK; grep -m1 VERSION /usr/local/hestia/conf/hestia.conf 2>/dev/null || echo 'AVISO: no parece un servidor HestiaCP'"

Write-Host "==> [2/6] Empaquetando y subiendo (.tgz por stdin sobre plink) ..." -ForegroundColor Cyan
Send-Tree

Write-Host "==> [3/6] Normalizando LF, sincronizando y ajustando permisos ..." -ForegroundColor Cyan
$sync = @"
set -eu
REMOTE_BASE='$RemoteBase'
TMP='/tmp/hestia-deploy'
command -v rsync    >/dev/null 2>&1 || { apt-get update -y >/dev/null 2>&1 || true; apt-get install -y rsync   >/dev/null 2>&1 || true; }
command -v dos2unix >/dev/null 2>&1 || { apt-get install -y dos2unix >/dev/null 2>&1 || true; }
mkdir -p "`$REMOTE_BASE"
find "`$TMP" -type f \( -name '*.sh' -o -name 'v-*' \) -exec dos2unix {} \; 2>/dev/null || true
for p in watchdog staging; do
    SRC="`$TMP/`$p"; DST="`$REMOTE_BASE/`$p"
    [ -d "`$SRC" ] || continue
    [ -d "`$DST/conf" ]  && cp -a "`$DST/conf"  "/tmp/hd-`$p-conf"  || true
    [ -d "`$DST/state" ] && cp -a "`$DST/state" "/tmp/hd-`$p-state" || true
    mkdir -p "`$DST"
    if command -v rsync >/dev/null 2>&1; then rsync -a --delete --exclude 'logs/' "`$SRC/" "`$DST/"; else cp -a "`$SRC/." "`$DST/"; fi
    [ -d "/tmp/hd-`$p-conf" ]  && { mkdir -p "`$DST/conf";  cp -a "/tmp/hd-`$p-conf/."  "`$DST/conf/";  rm -rf "/tmp/hd-`$p-conf"; }  || true
    [ -d "/tmp/hd-`$p-state" ] && { mkdir -p "`$DST/state"; cp -a "/tmp/hd-`$p-state/." "`$DST/state/"; rm -rf "/tmp/hd-`$p-state"; } || true
    mkdir -p "`$DST/state" "`$DST/logs"
done
chown -R root:root "`$REMOTE_BASE/watchdog" "`$REMOTE_BASE/staging"
find "`$REMOTE_BASE/watchdog/bin" "`$REMOTE_BASE/staging/bin" -type f -exec chmod 750 {} + 2>/dev/null || true
chmod 750 "`$REMOTE_BASE"/watchdog/*.sh "`$REMOTE_BASE"/staging/*.sh "`$REMOTE_BASE"/watchdog/checks/*.sh "`$REMOTE_BASE"/staging/lib/*.sh 2>/dev/null || true
chmod 640 "`$REMOTE_BASE"/watchdog/conf/*.conf "`$REMOTE_BASE"/staging/conf/*.conf 2>/dev/null || true
rm -rf "`$TMP"
echo 'Sincronizacion, LF y permisos OK'
"@
Invoke-RemoteScript $sync

if ($RunInstall) {
    Write-Host "==> [4/6] Ejecutando instaladores (cron + menu + botones Configure) ..." -ForegroundColor Cyan
    Invoke-RemoteScript "cd '$RemoteBase/watchdog' && bash install.sh"
    Invoke-RemoteScript "cd '$RemoteBase/staging'  && bash install.sh"
}
else { Write-Host "==> [4/6] RunInstall=false, omitido." }

if ($EnableUI) {
    Write-Host "==> [5/6] Publicando UI (symlinks) ..." -ForegroundColor Cyan
    Invoke-RemoteScript "ln -sf '$RemoteBase/watchdog/web' /usr/local/hestia/web/pluginwatchdog; ln -sf '$RemoteBase/staging/web' /usr/local/hestia/web/pluginstaging; echo 'UI publicada'"
}
else { Write-Host "==> [5/6] EnableUI=false, omitido." }

Write-Host "==> [6/6] Verificacion final ..." -ForegroundColor Cyan
Invoke-RemoteScript "hash -r; ls /usr/local/hestia/bin/v-watchdog-* /usr/local/hestia/bin/v-staging-* 2>/dev/null | wc -l | sed 's/^/comandos v-* instalados: /'; v-watchdog-status plain 2>/dev/null | head -2 || true"

Write-Host @"

============================================================
 Despliegue completado en $Server
------------------------------------------------------------
 KILL SWITCHES ACTIVOS POR DEFECTO (regla anti-catastrofe):
   Watchdog NO alerta hasta:   v-watchdog-config-set WD_KILL_SWITCH 'false'
   Staging NO hace push hasta: v-staging-config-set STG_PUSH_KILL_SWITCH 'false'
 UI (logado como admin, o STAGING visible para cada usuario):
   Menu superior: STAGING (todos) / WATCHDOG (admin)
   Server Settings -> seccion "Watchdog & Staging"
   https://${Server}:8083/pluginstaging/
   https://${Server}:8083/pluginwatchdog/
 Nota: el SSL Let's Encrypt del staging requiere que staging.<dominio>
       resuelva a la IP del servidor (DNS en tu proveedor).
============================================================
"@ -ForegroundColor Green
