@echo off
rem Boton de doble clic para publicar una version: sube el numero, commitea,
rem crea el tag vX.Y.Z y lo empuja. El tag dispara la release en GitHub Actions.
rem
rem Tambien acepta opciones del script, por ejemplo:
rem   Publicar release.bat -DryRun
rem   Publicar release.bat -Bump minor -Yes
setlocal enabledelayedexpansion

set "PRIMERO=%~1"
if not "!PRIMERO!"=="" if "!PRIMERO:~0,1!"=="-" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\release.ps1" %*
  goto :fin
)

set "BUMP=!PRIMERO!"
if "!BUMP!"=="" (
  echo.
  echo Que version publico?
  echo.
  echo   1^) patch   0.4.0  -^>  0.4.1   ^(arreglos^) [por defecto]
  echo   2^) minor   0.4.0  -^>  0.5.0   ^(funciones nuevas^)
  echo   3^) major   0.4.0  -^>  1.0.0   ^(cambio incompatible^)
  echo.
  set /p "OPCION=Numero [1]: "
  if "!OPCION!"=="2" ( set "BUMP=minor" ) else if "!OPCION!"=="3" ( set "BUMP=major" ) else ( set "BUMP=patch" )
)

echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\release.ps1" -Bump !BUMP!

:fin
echo.
pause
