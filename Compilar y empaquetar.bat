@echo off
setlocal
rem
rem  clubTivi - doble clic para compilar y empaquetar la version de Windows.
rem
rem  Antes de compilar corre flutter analyze y flutter test: si algo falla,
rem  se detiene y NO deja un zip a medias.
rem
rem  Tambien acepta opciones del script, por ejemplo:
rem    "Compilar y empaquetar.bat" -SkipBuild     (reempaqueta sin recompilar)
rem    "Compilar y empaquetar.bat" -Version 0.5.0
rem    "Compilar y empaquetar.bat" -SkipChecks    (solo emergencias)
rem

cd /d "%~dp0"
echo.
echo Compilando y empaquetando clubTivi para Windows...
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\package_windows.ps1" %*

if errorlevel 1 (
  echo.
  echo El paquete NO se genero. Revisa los mensajes de arriba.
) else (
  echo.
  echo Listo: el zip esta en la carpeta dist\
)
echo.
pause
