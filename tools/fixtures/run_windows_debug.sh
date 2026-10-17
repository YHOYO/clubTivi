#!/usr/bin/env bash
# Prepara y lanza la build Debug de Windows fuera de un "Developer Command Prompt".
#
# El CRT de depuracion de MSVC (vcruntime140d.dll, msvcp140d.dll, ...) no esta en
# el PATH del sistema, asi que el .exe Debug no arranca si se lanza desde una
# consola normal: Windows no encuentra las DLL y el proceso muere antes de que
# Flutter pueda conectar el depurador ("The log reader stopped unexpectedly, or
# never started").
#
# Este script copia esas DLL desde el "debug_nonredist" del MSVC mas nuevo que
# tenga instalado Visual Studio a la carpeta de salida, que es el primer sitio
# donde Windows busca una DLL. Funciona tanto con la disposicion local
# (`Microsoft Visual Studio/18/BuildTools/...`) como con la de CI
# (`Microsoft Visual Studio/2022/Enterprise/...`).
#
# Uso:
#   bash tools/fixtures/run_windows_debug.sh            # prepara la carpeta Debug
#   bash tools/fixtures/run_windows_debug.sh --release  # prepara la de Release
#   bash tools/fixtures/run_windows_debug.sh --run      # prepara y lanza la app

set -euo pipefail

MODE="debug"
RUN=0
for arg in "$@"; do
  case "$arg" in
    --release) MODE="release" ;;
    --run) RUN=1 ;;
    *) echo "argumento desconocido: $arg" >&2; exit 2 ;;
  esac
done

if [[ "$MODE" == "release" ]]; then
  OUT="build/windows/x64/runner/Release"
else
  OUT="build/windows/x64/runner/Debug"
fi
EXE="$OUT/clubtivi.exe"

if [[ ! -f "$EXE" ]]; then
  echo "no existe $EXE: compila antes con 'flutter build windows' ($MODE)" >&2
  exit 1
fi

# Solo las builds Debug enlazan contra el CRT de depuracion.
if [[ "$MODE" == "debug" ]]; then
  # Cualquier instancia de VS puede tener su propio debug_nonredist; usa la del
  # MSVC mas nuevo, que es la que compila la app (VS 18 = 14.5x, VS 17 = 14.4x).
  SRC=$(ls -d \
          "/c/Program Files/Microsoft Visual Studio"/*/*/VC/Redist/MSVC/*/debug_nonredist/x64/Microsoft.VC*.DebugCRT \
          "/c/Program Files (x86)/Microsoft Visual Studio"/*/*/VC/Redist/MSVC/*/debug_nonredist/x64/Microsoft.VC*.DebugCRT \
          2>/dev/null \
        | awk -F'/MSVC/' '{print $2 "=" $0}' | sort -V | tail -1 | cut -d= -f2-)
  if [[ -z "$SRC" ]]; then
    echo "aviso: no encontre debug_nonredist en Visual Studio; asumo que el CRT de depuracion ya es visible" >&2
  else
    echo "CRT de depuracion: $SRC"
    copied=0
    for dll in "$SRC"/*.dll; do
      cp -f "$dll" "$OUT/"
      copied=$((copied + 1))
    done
    echo "DLL de depuracion copiadas a $OUT: $copied"
  fi
fi

if [[ -f /c/Windows/System32/ucrtbased.dll ]]; then
  echo "ucrtbased.dll: presente en System32"
else
  echo "aviso: falta C:\\Windows\\System32\\ucrtbased.dll (instala 'Universal CRT Tools' del Windows SDK)" >&2
fi

if [[ "$RUN" == "1" ]]; then
  echo "lanzando $EXE"
  cd "$OUT"
  ./clubtivi.exe
fi
