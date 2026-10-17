@echo off
setlocal
rem
rem  clubTivi - doble clic para compilar y empaquetar la version de Windows.
rem
rem  Hace exactamente lo mismo que la integracion continua: compila la release,
rem  prepara el paquete portable (instrucciones + creador del acceso directo) y
rem  calcula su SHA-256. Todo queda en la carpeta dist\.
rem
rem  Desde la consola se le pueden pasar opciones al script, por ejemplo:
rem    "Compilar y empaquetar.bat" -SkipBuild     (reempaqueta sin recompilar)
rem    "Compilar y empaquetar.bat" -Version v0.5.0
rem

cd /d "%~dp0"
echo.
echo Compilando y empaquetando clubTivi para Windows...
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\package_windows.ps1" %*

if errorlevel 1 (
  echo.
  echo El empaquetado NO termino bien. Revisa los mensajes de arriba.
)
echo.
pause
