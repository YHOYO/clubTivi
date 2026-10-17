<#
.SYNOPSIS
    Publica una versión: sube el número, commitea, crea el tag y lo empuja.

.DESCRIPTION
    Hace de una vez los pasos que se olvidan o se hacen a medias:

      1. Sube la versión en pubspec.yaml y en el _currentVersion de
         lib/data/services/app_update_service.dart (el número que muestra la app
         y con el que decide si hay actualización: tienen que decir lo mismo).
      2. Pasa los tests (salvo -SkipTests).
      3. Commitea solo esos dos ficheros y crea el tag anotado v<versión>.
      4. Empuja la rama y el tag. El tag dispara .github/workflows/release.yml,
         que compila todas las plataformas y adjunta a la release el zip
         portable de Windows con su SHA256SUMS.txt.

    Se niega a tocar nada si el árbol de trabajo está sucio, si estás en un
    commit suelto (detached HEAD) o si el tag ya existe. Con -DryRun te enseña
    el plan sin cambiar nada.

.PARAMETER Bump
    Qué parte del número sube: patch (0.4.0 -> 0.4.1), minor (-> 0.5.0) o
    major (-> 1.0.0). Por defecto, patch. Se ignora si pasas -Version.

.PARAMETER Version
    Versión exacta, en lugar de -Bump. Acepta el tag (v1.2.3), una versión con
    número de build (1.2.3+9) y una pre-release (1.0.0-rc1).

.PARAMETER Build
    Número de build (+N). Por defecto, el actual más uno: los servicios de
    publicación exigen que nunca baje.

.PARAMETER Remote
    Remoto al que empujar. Por defecto, origin.

.PARAMETER SkipTests
    No pasa los tests. Úsalo solo si acabas de pasarlos tú.

.PARAMETER NoPush
    Commitea y crea el tag, pero no empuja. Te deja los dos comandos a mano.

.PARAMETER Yes
    No pide confirmación (para el botón de doble clic o la integración continua).

.PARAMETER DryRun
    Enseña el plan y termina. No escribe ficheros, ni commitea, ni etiqueta.

.EXAMPLE
    pwsh -File tools/release.ps1
    Sube el patch, pregunta y publica.

.EXAMPLE
    pwsh -File tools/release.ps1 -Bump minor -Yes

.EXAMPLE
    pwsh -File tools/release.ps1 -Version 1.0.0-rc1 -DryRun

.EXAMPLE
    pwsh -File tools/release.ps1 -NoPush
    Commit y tag en local, sin subirlos.
#>
[CmdletBinding()]
param(
    [ValidateSet('patch', 'minor', 'major')] [string] $Bump = 'patch',
    [string] $Version,
    [int] $Build,
    [string] $Remote = 'origin',
    [switch] $SkipTests,
    [switch] $NoPush,
    [switch] $Yes,
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ps-common.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
$pubspecPath = Join-Path $repoRoot 'pubspec.yaml'
$dartPath = Join-Path $repoRoot 'lib\data\services\app_update_service.dart'

if (-not (Test-Path $pubspecPath)) {
    Fail "no encuentro el repositorio de clubTivi: esperaba pubspec.yaml en $repoRoot."
}
if (-not (Test-Path $dartPath)) {
    Fail "no encuentro $dartPath, que es donde vive la versión que muestra la app."
}
Set-Location $repoRoot

# Compara solo el núcleo numérico (1.2.3): >0 si $A es mayor que $B.
function Compare-VersionCore {
    param([string] $A, [string] $B)
    $left = Split-VersionText -Text $A
    $right = Split-VersionText -Text $B
    if ($left.Major -ne $right.Major) { return $left.Major - $right.Major }
    if ($left.Minor -ne $right.Minor) { return $left.Minor - $right.Minor }
    return $left.Patch - $right.Patch
}

# ─── Estado del repositorio ─────────────────────────────────────────────────
Write-Step 'Comprobando el estado del repositorio'

# rev-parse devuelve «HEAD» (y código 0) cuando no hay rama: así este caso se
# explica con un mensaje nuestro en vez de con el fallo crudo de git.
$branch = ((Get-GitOutput -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')) -join '').Trim()
if ([string]::IsNullOrWhiteSpace($branch) -or $branch -eq 'HEAD') {
    Fail 'estás en un commit suelto (detached HEAD). Pásate a una rama antes de publicar.'
}

$dirty = Get-GitOutput -Arguments @('status', '--porcelain')
if ($dirty) {
    Write-Host ($dirty -join [Environment]::NewLine) -ForegroundColor Yellow
    Fail ('el árbol de trabajo tiene cambios sin commitear. El asistente solo commitea la subida de versión: ' +
        'commitéalos antes de publicar.')
}

$remoteUrl = (Get-GitOutput -Arguments @('remote', 'get-url', $Remote)) -join ''
if ([string]::IsNullOrWhiteSpace($remoteUrl)) {
    Fail "no existe el remoto '$Remote'."
}
Write-Note "rama:   $branch"
Write-Note "remoto: $Remote ($remoteUrl)"

# ─── Versión ────────────────────────────────────────────────────────────────
$currentRaw = Get-PubspecVersion -Path $pubspecPath
$current = Split-VersionText -Text $currentRaw
$currentText = '{0}.{1}.{2}' -f $current.Major, $current.Minor, $current.Patch

$nextText = ''
$buildFromVersion = 0
if (-not [string]::IsNullOrWhiteSpace($Version)) {
    $explicit = Split-VersionText -Text $Version
    $nextText = '{0}.{1}.{2}' -f $explicit.Major, $explicit.Minor, $explicit.Patch
    if (-not [string]::IsNullOrWhiteSpace($explicit.Pre)) { $nextText = "$nextText-$($explicit.Pre)" }
    $buildFromVersion = $explicit.Build
    if ($nextText -eq '0.0.0') { Fail "no entiendo la versión '$Version'." }
}
else {
    switch ($Bump) {
        'major' { $nextText = '{0}.0.0' -f ($current.Major + 1) }
        'minor' { $nextText = '{0}.{1}.0' -f $current.Major, ($current.Minor + 1) }
        default { $nextText = '{0}.{1}.{2}' -f $current.Major, $current.Minor, ($current.Patch + 1) }
    }
}

if ($PSBoundParameters.ContainsKey('Build')) {
    $nextBuild = $Build
}
elseif ($buildFromVersion -gt 0) {
    $nextBuild = $buildFromVersion
}
else {
    $nextBuild = $current.Build + 1
}
if ($nextBuild -le 0) { Fail "el número de build tiene que ser positivo (recibí $nextBuild)." }
if ($nextBuild -le $current.Build) {
    Fail ("el número de build nuevo ($nextBuild) no es mayor que el actual ($($current.Build)): " +
        'las tiendas y los servicios de publicación lo rechazan.')
}

$coreComparison = Compare-VersionCore -A $nextText -B $currentText
$sameCoreNewPrerelease = ($coreComparison -eq 0 -and $nextText.Contains('-') -and $nextText -ne $currentText)
if ($coreComparison -lt 0 -or ($coreComparison -eq 0 -and -not $sameCoreNewPrerelease)) {
    $hint = if ($coreComparison -eq 0) { ' Usa -Bump o -Version para subirla.' } else { '' }
    Fail "la versión nueva ($nextText) no es mayor que la actual ($currentText).$hint"
}

$nextRaw = "$nextText+$nextBuild"
$tag = "v$nextText"
$commitMessage = "🚀 Release v$nextText"

$existingTag = Get-GitOutput -Arguments @('tag', '--list', $tag)
if ($existingTag) { Fail "el tag $tag ya existe en este repositorio." }

# ─── Plan ───────────────────────────────────────────────────────────────────
Write-Step 'Plan de publicación'
Write-Host "  Versión ...: $currentRaw  ->  $nextRaw"
Write-Host '  Ficheros ..: pubspec.yaml'
Write-Host '               lib/data/services/app_update_service.dart'
Write-Host "  Commit ....: $commitMessage"
Write-Host "  Tag .......: $tag (anotado)"
if ($NoPush) {
    Write-Host '  Push ......: NO (-NoPush)'
}
else {
    Write-Host "  Push ......: rama $branch y tag $tag a $Remote"
    Write-Host '               (el tag compila la release en GitHub Actions)'
}
if ($SkipTests) { Write-Host '  Tests .....: omitidos (-SkipTests)' -ForegroundColor Yellow }

if ($DryRun) {
    Write-Host ''
    Write-Host 'Simulación: no he tocado nada.' -ForegroundColor Green
    exit 0
}

if (-not $Yes) {
    Write-Host ''
    $answer = Read-Host '¿Publico esta versión? [s/N]'
    if ($answer -notmatch '^[sSyY]') {
        Write-Host 'Cancelado, no he tocado nada.' -ForegroundColor Yellow
        exit 0
    }
}

# ─── Tests ──────────────────────────────────────────────────────────────────
if (-not $SkipTests) {
    $flutter = Resolve-Flutter
    Write-Step 'Pasando los tests (flutter test)'
    & $flutter test
    if ($LASTEXITCODE -ne 0) {
        Fail "los tests fallaron (código $LASTEXITCODE): no publico nada. Arregla o usa -SkipTests."
    }
}

# ─── Subir la versión ───────────────────────────────────────────────────────
Write-Step "Subiendo la versión a $nextRaw"

$pubspecText = [System.IO.File]::ReadAllText($pubspecPath)
$pubspecReplaced = [regex]::Replace($pubspecText, '(?m)^(\s*version:\s*)\S+', ('${1}' + $nextRaw), 1)
if ($pubspecReplaced -eq $pubspecText) { Fail 'no he podido cambiar la versión en pubspec.yaml.' }
Write-Utf8File -Path $pubspecPath -Content $pubspecReplaced
Write-Note "pubspec.yaml ...............: version: $nextRaw"

# La app compara su versión con la del tag, así que este número no puede quedarse atrás.
$dartText = [System.IO.File]::ReadAllText($dartPath)
$dartReplaced = [regex]::Replace($dartText, "(const _currentVersion = ')[^']*(';)", ('${1}' + $nextText + '${2}'), 1)
if ($dartReplaced -eq $dartText) {
    Fail ("no encuentro «const _currentVersion = '...';» en $dartPath. " +
        'Actualiza el patrón de este script si el fichero ha cambiado de forma.')
}
Write-Utf8File -Path $dartPath -Content $dartReplaced
Write-Note "app_update_service.dart ....: _currentVersion = '$nextText'"

# ─── Commit y tag ───────────────────────────────────────────────────────────
# El mensaje va en un fichero UTF-8 en vez de por argumento: PowerShell 5.1
# codifica los argumentos con la página de códigos de la consola y el emoji del
# asunto llegaría a git como «?».
Write-Step "Commit y tag $tag"
Invoke-Git -Arguments @('add', '--', 'pubspec.yaml', 'lib/data/services/app_update_service.dart') -What 'git add'

$messagePath = Join-Path ([System.IO.Path]::GetTempPath()) 'clubtivi-release-message.txt'
Write-Utf8File -Path $messagePath -Content $commitMessage
try {
    Invoke-Git -Arguments @('commit', '-F', $messagePath) -What 'git commit'
}
finally {
    Remove-Item -LiteralPath $messagePath -Force -ErrorAction SilentlyContinue
}
Invoke-Git -Arguments @('tag', '-a', $tag, '-m', "clubTivi $tag") -What 'git tag'

# ─── Push ───────────────────────────────────────────────────────────────────
if ($NoPush) {
    Write-Step 'Sin empujar (-NoPush)'
    Write-Host '  Cuando quieras publicarla de verdad:'
    Write-Host "    git push $Remote $branch"
    Write-Host "    git push $Remote $tag"
}
else {
    Write-Step "Empujando a $Remote"
    $remoteTag = Get-GitOutput -Arguments @('ls-remote', '--tags', $Remote, "refs/tags/$tag")
    if ($remoteTag) { Fail "el tag $tag ya existe en ${Remote}: usa otra versión." }

    Invoke-Git -Arguments @('push', $Remote, $branch) -What "git push $Remote $branch"
    Invoke-Git -Arguments @('push', $Remote, $tag) -What "git push $Remote $tag"
}

# ─── Resumen ────────────────────────────────────────────────────────────────
$commit = (Get-GitOutput -Arguments @('log', '-1', '--format=%h %s')) -join ''
Write-Host ''
Write-Host 'Listo.' -ForegroundColor Green
Write-Host "  Versión ....: $nextRaw"
Write-Host "  Commit .....: $commit"
Write-Host "  Tag ........: $tag"
if ($NoPush) {
    Write-Host '  Release ....: en cuanto empujes el tag, GitHub Actions compila y publica el zip con su SHA256SUMS.txt.'
}
else {
    Write-Host '  Release ....: en marcha. GitHub Actions (.github/workflows/release.yml) está compilando'
    Write-Host '                el zip portable de Windows y su SHA256SUMS.txt; los verás en la release.'
    Write-Host "                Ver el estado: gh run list --workflow 'Release (tag)'"
}
exit 0
