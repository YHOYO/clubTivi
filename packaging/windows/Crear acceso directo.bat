@echo off
setlocal
rem
rem  clubTivi - crea un acceso directo con el icono de la aplicacion.
rem
rem  Uso normal:      doble clic sobre este fichero. El acceso directo aparece
rem                   en el escritorio (o en el de OneDrive, si lo rediriges).
rem  Otro destino:    Crear acceso directo.bat "D:\Mi carpeta"
rem

set "CLUBTIVI_APP=%~dp0clubtivi.exe"
if not exist "%CLUBTIVI_APP%" (
  echo.
  echo No encuentro clubtivi.exe junto a este fichero.
  echo Descomprime el paquete completo y vuelve a intentarlo.
  echo.
  pause
  exit /b 1
)

if not "%~1"=="" set "CLUBTIVI_DEST=%~1"

powershell -NoProfile -ExecutionPolicy Bypass -Command "$app = $env:CLUBTIVI_APP; $d = $env:CLUBTIVI_DEST; if ([string]::IsNullOrWhiteSpace($d)) { $d = [Environment]::GetFolderPath('Desktop') }; if ([string]::IsNullOrWhiteSpace($d)) { Write-Host 'No encuentro tu escritorio. Indica la carpeta destino como primer argumento.'; exit 1 }; New-Item -ItemType Directory -Force -Path $d | Out-Null; $dest = Join-Path $d 'clubTivi.lnk'; $s = (New-Object -ComObject WScript.Shell).CreateShortcut($dest); $s.TargetPath = $app; $s.WorkingDirectory = (Split-Path $app); $s.IconLocation = $app + ',0'; $s.Description = 'clubTivi'; $s.Save(); Write-Host ''; Write-Host ('Acceso directo creado en: ' + $dest); Write-Host 'La aplicacion se abre siempre desde su carpeta: no muevas solo el acceso directo.'"

if errorlevel 1 (
  echo.
  echo No se pudo crear el acceso directo.
)
echo.
pause
