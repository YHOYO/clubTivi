<#
    Helpers compartidos por los scripts de tools/.

    Se cargan desde otro script con:

        . (Join-Path $PSScriptRoot 'ps-common.ps1')

    Aquí solo hay funciones: no cambian la carpeta de trabajo, ni el modo
    estricto, ni imprimen nada por su cuenta.
#>

# Mensaje de paso.
function Write-Step {
    param([string] $Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

# Detalle subordinado a un paso.
function Write-Note {
    param([string] $Message)
    Write-Host "    $Message" -ForegroundColor DarkGray
}

# Aborta con un mensaje claro (código de salida 1).
function Fail {
    param([string] $Message)
    Write-Host ''
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

# Ejecuta git y aborta si falla, mostrando el comando.
function Invoke-Git {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [string] $What
    )
    & git @Arguments
    if ($LASTEXITCODE -ne 0) {
        if ([string]::IsNullOrWhiteSpace($What)) { $What = "git $($Arguments -join ' ')" }
        Fail "$What falló (código $LASTEXITCODE)."
    }
}

# Salida de un comando git, como líneas. Aborta si git falla.
function Get-GitOutput {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $output = & git @Arguments
    if ($LASTEXITCODE -ne 0) { Fail "git $($Arguments -join ' ') falló (código $LASTEXITCODE)." }
    return $output
}

# Busca el SDK de Flutter: PATH, FLUTTER_ROOT y las instalaciones habituales.
function Resolve-Flutter {
    $command = Get-Command flutter -ErrorAction SilentlyContinue
    if ($command -and $command.Source) { return $command.Source }

    $candidates = @()
    if ($env:FLUTTER_ROOT) { $candidates += (Join-Path $env:FLUTTER_ROOT 'bin\flutter.bat') }
    if ($env:USERPROFILE) {
        $candidates += (Join-Path $env:USERPROFILE 'develop\flutter\bin\flutter.bat')
        $candidates += (Join-Path $env:USERPROFILE 'flutter\bin\flutter.bat')
        $candidates += (Join-Path $env:USERPROFILE 'fvm\default\bin\flutter.bat')
    }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'flutter\bin\flutter.bat') }
    $candidates += 'C:\src\flutter\bin\flutter.bat'
    $candidates += 'C:\flutter\bin\flutter.bat'

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    Fail 'no encuentro flutter. Añádelo al PATH o define la variable FLUTTER_ROOT.'
}

# Versión tal cual figura en pubspec.yaml (por ejemplo 0.4.0+5).
function Get-PubspecVersion {
    param([Parameter(Mandatory)][string] $Path)
    $match = Select-String -Path $Path -Pattern '^\s*version:\s*([^\s#]+)' | Select-Object -First 1
    if (-not $match) { Fail "no encuentro la versión en $Path." }
    return $match.Matches[0].Groups[1].Value
}

# Descompone 1.2.3-rc1+7 en sus partes. Lo que no se entiende queda en 0.
function Split-VersionText {
    param([Parameter(Mandatory)][string] $Text)

    $core = $Text.Trim() -replace '^[vV]', ''
    $build = 0
    $pre = ''

    if ($core.Contains('+')) {
        $split = $core.Split('+', 2)
        $core = $split[0]
        [void][int]::TryParse($split[1].Trim(), [ref] $build)
    }
    if ($core.Contains('-')) {
        $split = $core.Split('-', 2)
        $core = $split[0]
        $pre = $split[1]
    }

    $numbers = $core.Split('.')
    $major = 0
    $minor = 0
    $patch = 0
    if ($numbers.Count -gt 0) { [void][int]::TryParse($numbers[0].Trim(), [ref] $major) }
    if ($numbers.Count -gt 1) { [void][int]::TryParse($numbers[1].Trim(), [ref] $minor) }
    if ($numbers.Count -gt 2) { [void][int]::TryParse($numbers[2].Trim(), [ref] $patch) }

    return [pscustomobject]@{
        Major = $major
        Minor = $minor
        Patch = $patch
        Pre   = $pre
        Build = $build
    }
}

# «dueno/repo» a partir de una URL de git, para que la app consulte las
# releases de este mismo repositorio y no las del proyecto original.
function Get-OriginRepo {
    param([string] $RemoteUrl)
    if ([string]::IsNullOrWhiteSpace($RemoteUrl)) { return '' }

    $clean = $RemoteUrl.Trim()
    $clean = $clean -replace '^git@[^:]+:', ''      # git@github.com:dueno/repo.git
    $clean = $clean -replace '^[a-z]+://[^/]+/', ''  # https://github.com/dueno/repo.git
    $clean = $clean -replace '\.git$', ''

    if ($clean -match '^([^/\s]+)/([^/\s]+)$') { return ($Matches[1] + '/' + $Matches[2]) }
    return ''
}

# Escribe texto en UTF-8 sin BOM (lo que esperan pubspec.yaml y el código Dart).
function Write-Utf8File {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Content
    )
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}
