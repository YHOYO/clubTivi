# Compilar clubTivi en Windows

Todo desde la raíz del repositorio. Necesitas Flutter 3.29+ y Visual Studio 2022
con el workload "Desarrollo para escritorio con C++".

## Una sola vez

```powershell
flutter pub get
```

## Probar mientras programas (lo más rápido)

```powershell
flutter run -d windows
```

Arranca en modo debug: guardas un archivo y pulsas **r** para recargar en
caliente, **R** para reiniciar y **q** para cerrar.

## Compilar la release

```powershell
flutter build windows --release
```

El ejecutable queda en `build\windows\x64\runner\Release\clubtivi.exe`. Ese `.exe`
**no funciona solo**: necesita las `.dll` y la carpeta `data\` que están a su
lado. Para llevarlo a otro PC, usa el empaquetado.

## Compilar y empaquetar (un solo paso)

Doble clic en **`Compilar y empaquetar.bat`**, o desde consola:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\package_windows.ps1
```

Qué hace, en orden:

1. `flutter analyze` — si hay cualquier problema, **aborta** (no compila nada).
2. `flutter test` — si falla un test, **aborta** (no compila nada).
3. `flutter pub get` y `flutter build windows --release`.
4. Prepara `dist\clubTivi\` con el ejecutable, las DLL, `data\` y un `LEEME.txt`
   con la versión y la fecha.
5. Genera `dist\clubTivi-windows-x64-<version>.zip` y `dist\SHA256SUMS.txt`
   (en formato `sha256sum -c`, con saltos de línea LF).

Solo escribe en `dist\` y en `build\`.

Opciones:

```powershell
"Compilar y empaquetar.bat" -SkipBuild            # reempaqueta sin validar ni compilar
"Compilar y empaquetar.bat" -Version 0.5.0       # nombre/versión del zip
"Compilar y empaquetar.bat" -SkipChecks          # emergencias: se salta analyze y test
```

Comprobar el zip descargado:

```bash
cd dist && sha256sum -c SHA256SUMS.txt
```

## Los checks sueltos

```powershell
flutter analyze
flutter test
flutter test test/stremio_addons_screen_test.dart   # un solo archivo
```

## Publicar una versión

Este checkout no tiene script de publicación: se hace a mano.

```powershell
# 1. Sube la versión en pubspec.yaml y en lib\data\services\app_update_service.dart
# 2. Empaqueta y comprueba que el zip arranca
git add -A
git commit -m "release: 0.5.0"
git tag v0.5.0
git push && git push --tags
```

Después: adjuntar `dist\clubTivi-windows-x64-<version>.zip` y `dist\SHA256SUMS.txt`
a la release del tag en GitHub.

## Problemas típicos

| Síntoma | Qué mirar |
|---|---|
| Falla al compilar en Windows | Visual Studio sin el workload de C++ de escritorio |
| `error C1083: 'atlstr.h'` al compilar | `flutter_secure_storage_windows` usa ATL. `windows/CMakeLists.txt` busca `atlmfc` en la instalación de Visual Studio; si ninguna la tiene, instala el componente «C++ ATL» y vuelve a compilar |
| Faltan plugins tras tocar `pubspec.yaml` | `flutter clean` y luego `flutter pub get` |
| El script dice `ERROR: flutter test fallo` | Arregla los tests: es la puerta de calidad, no un fallo del script |
| `ERROR: clubTivi esta abierto...` | Cierra la app antes de reempaquetar: bloquea el `clubtivi.exe` de `dist\clubTivi` |
| El `.exe` no arranca al copiarlo solo | Le faltan las DLL y `data\`; usa el zip |
