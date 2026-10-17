<#
.SYNOPSIS
    Valida, compila y empaqueta clubTivi para Windows (64 bits).

.DESCRIPTION
    Un solo paso, con la misma puerta de calidad que usaria la integracion
    continua:

      1. flutter analyze  -> si hay problemas, aborta (no se compila nada).
      2. flutter test     -> si algun test falla, aborta (no se compila nada).
      3. flutter pub get y flutter build windows --release.
      4. Prepara dist/clubTivi/ con el ejecutable, sus DLL, la carpeta data
         y un LEEME.txt con la version y la fecha de esta build.
      5. Genera dist/clubTivi-windows-x64-<version>.zip y SHA256SUMS.txt.
      6. Borra los zips de versiones anteriores: en dist/ solo queda la ultima.

    Solo escribe dentro de dist/ (y en build/, que es de Flutter).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\package_windows.ps1

.EXAMPLE
    # Reempaquetar la build que ya existe, sin validar ni compilar:
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\package_windows.ps1 -SkipBuild

.EXAMPLE
    # Version explicita para el nombre del zip:
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\package_windows.ps1 -Version 0.5.0
#>
[CmdletBinding()]
param(
    # Version del paquete (nombre del zip y LEEME.txt). Por defecto, la de
    # pubspec.yaml (0.4.0+5 -> 0.4.0). Se acepta el tag (v0.5.0).
    [string] $Version,

    # Carpeta donde dejar el paquete. Por defecto, dist/ en la raiz del repo.
    [string] $OutputDir,

    # Reempaquetar la build que ya hay, sin validar ni compilar.
    [switch] $SkipBuild,

    # Saltarse analyze y test. Solo para emergencias: el paquete puede salir roto.
    [switch] $SkipChecks
)

$ErrorActionPreference = 'Stop'

function Write-Step([string] $text) { Write-Host ''; Write-Host "==> $text" -ForegroundColor Cyan }
function Write-Note([string] $text) { Write-Host "    $text" -ForegroundColor DarkGray }
function Fail([string] $text) {
    Write-Host ''
    Write-Host "ERROR: $text" -ForegroundColor Red
    exit 1
}

# --- Donde estamos ---------------------------------------------------------
$repoRoot = Split-Path -Parent $PSScriptRoot
$pubspec  = Join-Path $repoRoot 'pubspec.yaml'
if (-not (Test-Path $pubspec) -or -not (Test-Path (Join-Path $repoRoot 'windows'))) {
    Fail "no encuentro el repositorio de clubTivi: se esperaban pubspec.yaml y windows/ en $repoRoot."
}
Set-Location $repoRoot

# --- Version ---------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Version)) {
    $line = Select-String -LiteralPath $pubspec -Pattern '^version:\s*(.+)$' | Select-Object -First 1
    if (-not $line) { Fail "no encuentro la linea 'version:' en $pubspec." }
    $Version = $line.Matches[0].Groups[1].Value.Trim().Trim("'").Trim('"')
}
# El tag (v0.5.0) y el pubspec (0.4.0+5) valen igual: nombre limpio.
$Version = ($Version -replace '^[vV]', '') -replace '\+.*$', ''
if ([string]::IsNullOrWhiteSpace($Version)) { Fail 'la version quedo vacia.' }

# Aviso util: la version que muestra Ajustes sale de una constante del codigo.
$appVersionFile = Join-Path $repoRoot 'lib\data\services\app_update_service.dart'
if (Test-Path $appVersionFile) {
    $match = Select-String -LiteralPath $appVersionFile -Pattern "_currentVersion\s*=\s*'([^']+)'" | Select-Object -First 1
    if ($match) {
        $appVersion = $match.Matches[0].Groups[1].Value
        if ($appVersion -ne $Version) {
            Write-Host "AVISO: pubspec.yaml dice $Version pero la app muestra $appVersion (app_update_service.dart)." -ForegroundColor Yellow
        }
    }
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) { $OutputDir = Join-Path $repoRoot 'dist' }
if (-not [System.IO.Path]::IsPathRooted($OutputDir)) { $OutputDir = Join-Path $repoRoot $OutputDir }

# --- Flutter ---------------------------------------------------------------
function Resolve-Flutter {
    $command = Get-Command flutter -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $candidates = @(
        "$env:LOCALAPPDATA\flutter\bin\flutter.bat",
        "$env:USERPROFILE\flutter\bin\flutter.bat",
        "$env:USERPROFILE\develop\flutter\bin\flutter.bat",
        'C:\flutter\bin\flutter.bat',
        'C:\src\flutter\bin\flutter.bat'
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }
    Fail 'no encuentro flutter. Agrega flutter\bin al PATH y vuelve a intentarlo.'
}

$flutter = $null
if (-not $SkipBuild) {
    $flutter = Resolve-Flutter

    # --- Puerta de calidad -------------------------------------------------
    if (-not $SkipChecks) {
        Write-Step 'Analisis estatico (flutter analyze)'
        & $flutter analyze
        if ($LASTEXITCODE -ne 0) {
            Fail "flutter analyze encontro problemas (codigo $LASTEXITCODE). No se compilo nada: arreglalo y vuelve a ejecutar."
        }

        Write-Step 'Tests (flutter test)'
        & $flutter test
        if ($LASTEXITCODE -ne 0) {
            Fail "flutter test fallo (codigo $LASTEXITCODE). No se compilo nada: arregla los tests y vuelve a ejecutar."
        }
    }
    else {
        Write-Host ''
        Write-Host 'AVISO: -SkipChecks, no se ejecutaron analyze ni test.' -ForegroundColor Yellow
    }

    Write-Step 'Instalando dependencias (flutter pub get)'
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) { Fail "flutter pub get fallo (codigo $LASTEXITCODE)." }

    Write-Step 'Compilando la release de Windows (tarda un par de minutos)'
    & $flutter build windows --release
    if ($LASTEXITCODE -ne 0) { Fail "la compilacion fallo (codigo $LASTEXITCODE)." }
}
else {
    Write-Note '-SkipBuild: se reempaqueta la build existente, sin analyze, test ni compilacion.'
}

# --- La build --------------------------------------------------------------
$releaseDir = Join-Path $repoRoot 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $releaseDir 'clubtivi.exe'))) {
    Fail "no hay ninguna build en $releaseDir. Vuelve a ejecutarlo sin -SkipBuild."
}

# --- Paquete ---------------------------------------------------------------
Write-Step "Preparando el paquete portable (clubTivi $Version)"
$stage = Join-Path $OutputDir 'clubTivi'
if (Test-Path $stage) {
    # Si la app esta abierta DESDE el paquete anterior, Windows no deja borrar su
    # clubtivi.exe. Mejor decirlo claro que soltar un Access Denied a medias.
    try {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop
    }
    catch {
        $running = @(Get-Process -Name clubtivi -ErrorAction SilentlyContinue)
        if ($running.Count -gt 0) {
            Fail "clubTivi esta abierto ($($running.Count) proceso(s)) y bloquea la carpeta del paquete (${stage}). Cierra la app y vuelve a ejecutar el script."
        }
        Fail "no puedo vaciar la carpeta del paquete (${stage}): $_"
    }
}
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item -Path (Join-Path $releaseDir '*') -Destination $stage -Recurse -Force

$leeme = @"
clubTivi $Version - Windows 64 bits
Empaquetado el $((Get-Date).ToString('dd/MM/yyyy'))

COMO ABRIRLO
  1. Descomprime el zip en una carpeta tuya (no hace falta instalador).
  2. Doble clic en clubtivi.exe.

  El ejecutable necesita las DLL y la carpeta data que vienen al lado: si lo
  sacas solo, no arranca. Para un acceso directo, arrastra clubtivi.exe al
  escritorio con el boton derecho -> Enviar a -> Escritorio.

DATOS
  Canales, favoritos y ajustes se guardan en tu carpeta de usuario.

EN RED
  Algunos canales IPTV necesitan red local sin bloqueos. Si el video no carga,
  prueba otra fuente del mismo canal.

clubTivi es software libre (Apache-2.0): https://github.com/clubanderson/clubTivi
"@
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText((Join-Path $stage 'LEEME.txt'), $leeme, $utf8Bom)

$zipName = "clubTivi-windows-x64-$Version.zip"
$zipPath = Join-Path $OutputDir $zipName
if (Test-Path $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Write-Step "Comprimiendo $zipName"
Compress-Archive -Path $stage -DestinationPath $zipPath -CompressionLevel Optimal -Force

# --- Limpieza de paquetes anteriores ---------------------------------------
# dist/ es la carpeta de la ultima version: dejar zips viejos al lado del nuevo
# invita a publicar o probar el equivocado. Se borran despues de crear el zip
# actual, para no quedarse sin paquete si la compresion falla.
Write-Step 'Eliminando paquetes de versiones anteriores'
$oldZips = @(
    Get-ChildItem -LiteralPath $OutputDir -Filter 'clubTivi-windows-x64-*.zip' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne $zipName }
)
if ($oldZips.Count -eq 0) {
    Write-Note 'no habia zips anteriores'
}
else {
    foreach ($oldZip in $oldZips) {
        Remove-Item -LiteralPath $oldZip.FullName -Force
        Write-Note "borrado $($oldZip.Name)"
    }
}

# --- SHA-256 ---------------------------------------------------------------
# Se calcula sobre el zip ya cerrado, en formato `sha256sum -c` (hash, dos
# espacios, nombre del fichero).
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest = Join-Path $OutputDir 'SHA256SUMS.txt'
# Salto de linea LF explicito: con CRLF, `sha256sum -c` en Linux/Git Bash busca
# un fichero que termina en "\r" y falla.
[System.IO.File]::WriteAllText($manifest, "$hash  $zipName`n", (New-Object System.Text.UTF8Encoding($false)))

# --- Resumen ---------------------------------------------------------------
$sizeMb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 1)
Write-Host ''
Write-Host 'Listo.' -ForegroundColor Green
Write-Host "  Version ....: $Version"
Write-Host "  ZIP ........: $zipPath ($sizeMb MB)"
Write-Host "  SHA-256 ....: $hash"
Write-Host "  Manifiesto .: $manifest"
Write-Host "  Carpeta ....: $stage"
Write-Host ''
Write-Host 'Para probarlo: descomprime el zip en otra carpeta y abre clubtivi.exe desde ahi.'
exit 0
