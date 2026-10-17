<#
.SYNOPSIS
    Compila y empaqueta clubTivi para Windows (64 bits).

.DESCRIPTION
    Un solo paso, el mismo en tu máquina y en la integración continua:

      1. Resuelve el SDK de Flutter.
      2. flutter pub get y flutter build windows --release.
      3. Prepara dist/clubTivi/ con el ejecutable, sus DLL, la subcarpeta data
         y las instrucciones (LEEME.txt) con la versión y la fecha puestas, más
         el creador del acceso directo.
      4. Genera dist/clubTivi-windows-x64-<version>.zip y su SHA256SUMS.txt.

    No toca nada fuera de dist/: ni el repositorio ni tus datos de usuario.

.EXAMPLE
    pwsh -File tools/package_windows.ps1

.EXAMPLE
    # Reempaquetar la build que ya existe, sin volver a compilar:
    pwsh -File tools/package_windows.ps1 -SkipBuild

.EXAMPLE
    # Como lo llama la integración continua, con la versión del tag:
    pwsh -File tools/package_windows.ps1 -Version v0.5.0

.EXAMPLE
    # Apuntando el comprobador de actualizaciones a otro repositorio:
    pwsh -File tools/package_windows.ps1 -UpdateRepo YHOYO/clubTivi
#>
[CmdletBinding()]
param(
    # Versión del paquete: va en el nombre del zip y en las instrucciones. Por
    # defecto, la del pubspec.yaml (0.4.0+5 -> 0.4.0). Se acepta el tag (v0.5.0).
    [string] $Version,

    # Carpeta donde dejar el paquete. Por defecto, dist/ en la raíz del repo.
    [string] $OutputDir,

    # Repositorio del que la app consulta las actualizaciones, como
    # «dueno/repo». Por defecto se deduce del remoto origin. Se compila dentro
    # del binario (--dart-define), así que cada build apunta a su propia
    # release.
    [string] $UpdateRepo,

    # Reempaquetar la build que ya hay, sin compilar.
    [switch] $SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ps-common.ps1')

# ─── Dónde estamos ──────────────────────────────────────────────────────────
$repoRoot = Split-Path -Parent $PSScriptRoot
$pubspec = Join-Path $repoRoot 'pubspec.yaml'
if (-not (Test-Path $pubspec) -or -not (Test-Path (Join-Path $repoRoot 'windows'))) {
    Fail "no encuentro el repositorio de clubTivi: se esperaban pubspec.yaml y windows/ en $repoRoot."
}
Set-Location $repoRoot

# ─── Versión ────────────────────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = Get-PubspecVersion -Path $pubspec
}
# El tag (v0.5.0) y el pubspec (0.4.0+5) valen igual: nombre limpio.
$Version = ($Version -replace '^[vV]', '') -replace '\+.*$', ''
if ([string]::IsNullOrWhiteSpace($Version)) { Fail 'la versión quedó vacía.' }

# Sin -UpdateRepo, la app mira las releases del remoto del que se compila;
# así un fork no anuncia las versiones del proyecto original.
if ([string]::IsNullOrWhiteSpace($UpdateRepo)) {
    try {
        $originUrl = & git -C $repoRoot remote get-url origin 2>$null
        if ($LASTEXITCODE -eq 0) { $UpdateRepo = Get-OriginRepo -RemoteUrl ($originUrl -join '') }
    }
    catch {
        $UpdateRepo = ''
    }
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) { $OutputDir = Join-Path $repoRoot 'dist' }
if (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir = Join-Path $repoRoot $OutputDir
}

# ─── Flutter ────────────────────────────────────────────────────────────────
if (-not $SkipBuild) {
    $flutter = Resolve-Flutter

    Write-Step 'Instalando dependencias (flutter pub get)'
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) { Fail "flutter pub get falló (código $LASTEXITCODE)." }

    Write-Step 'Compilando la release de Windows (tarda un par de minutos)'
    $buildArgs = @('build', 'windows', '--release')
    if (-not [string]::IsNullOrWhiteSpace($UpdateRepo)) {
        $buildArgs += "--dart-define=CLUBTIVI_UPDATE_REPO=$UpdateRepo"
        Write-Note "la app buscará actualizaciones en github.com/$UpdateRepo"
    }
    & $flutter @buildArgs
    if ($LASTEXITCODE -ne 0) { Fail "la compilación falló (código $LASTEXITCODE)." }
}

# ─── La build ───────────────────────────────────────────────────────────────
$releaseDir = Join-Path $repoRoot 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $releaseDir 'clubtivi.exe'))) {
    Fail "no hay ninguna build en $releaseDir. Vuelve a ejecutarlo sin -SkipBuild."
}

# ─── Paquete ────────────────────────────────────────────────────────────────
Write-Step "Preparando el paquete portable (clubTivi $Version)"
$stage = Join-Path $OutputDir 'clubTivi'
if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item -Path (Join-Path $releaseDir '*') -Destination $stage -Recurse -Force

# Las instrucciones salen con la versión y la fecha de esta build; el creador
# del acceso directo se copia tal cual, que su texto no cambia.
$templates = Join-Path $repoRoot 'packaging\windows'
$leemeTemplate = Join-Path $templates 'LEEME.txt'
if (-not (Test-Path $leemeTemplate)) { Fail "no encuentro la plantilla $leemeTemplate." }
$leeme = [System.IO.File]::ReadAllText($leemeTemplate)
$leeme = $leeme.Replace('@@VERSION@@', $Version).Replace('@@FECHA@@', (Get-Date).ToString('dd/MM/yyyy'))
[System.IO.File]::WriteAllText(
    (Join-Path $stage 'LEEME.txt'),
    $leeme,
    (New-Object System.Text.UTF8Encoding($true)))
Copy-Item -LiteralPath (Join-Path $templates 'Crear acceso directo.bat') `
    -Destination (Join-Path $stage 'Crear acceso directo.bat') -Force

$zipName = "clubTivi-windows-x64-$Version.zip"
$zipPath = Join-Path $OutputDir $zipName
if (Test-Path $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Write-Step "Comprimiendo $zipName"
Compress-Archive -Path $stage -DestinationPath $zipPath -CompressionLevel Optimal -Force

# ─── SHA-256 ────────────────────────────────────────────────────────────────
# Se calcula sobre el zip ya cerrado, y se deja junto a él en formato
# `sha256sum -c` (hash, dos espacios, nombre del fichero).
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest = Join-Path $OutputDir 'SHA256SUMS.txt'
[System.IO.File]::WriteAllLines(
    $manifest,
    [string[]] @("$hash  $zipName"),
    (New-Object System.Text.UTF8Encoding($false)))

# ─── Resumen ────────────────────────────────────────────────────────────────
$sizeMb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 1)
Write-Host ''
Write-Host 'Listo.' -ForegroundColor Green
Write-Host "  Versión ....: $Version"
Write-Host "  ZIP ........: $zipPath ($sizeMb MB)"
Write-Host "  SHA-256 ....: $hash"
Write-Host "  Manifiesto .: $manifest"
Write-Host "  Carpeta ....: $stage"
Write-Host ''
Write-Host 'Para probarlo: descomprime el zip en otra carpeta y abre clubtivi.exe desde ahí.'
Write-Host 'Publicarlo es adjuntar el zip y SHA256SUMS.txt a la release.'
exit 0
