# Reproducción P2P (rqbit)

Una fuente con `infoHash` (Torrentio o cualquier addon Stremio) no necesita un
servicio debrid: la app arranca **rqbit**, un cliente BitTorrent escrito en
Rust, lo usa como motor local y sirve el archivo elegido desde su endpoint de
streaming. Sin debrid, esas fuentes dejan de aparecer como no disponibles en
escritorio.

## Cómo funciona

```
addon ──infoHash + fileIdx + magnet──► RqbitEngine
                                        │ 1. localiza el binario
                                        │ 2. RqbitSupervisor lo arranca en 127.0.0.1:<puerto libre>
                                        │ 3. POST /torrents   (magnet, con sus trackers)
                                        │ 4. GET  /torrents/{id} y /torrents/{id}/stats/v1 hasta tener metadatos
                                        │ 5. elige el archivo (fileIdx del addon o el vídeo incluido más grande)
                                        ▼
                         http://127.0.0.1:<puerto>/torrents/{id}/stream/{idx}  ──► reproductor (mpv)
```

- El reproductor pide el stream con `Range`; rqbit responde `206` y prioriza
  las piezas necesarias. No hay que esperar a que el torrent termine.
- El proceso escucha **solo en loopback** y se mata al cerrar la ventana. Al
  arrancar se limpia un `rqbit` huérfano de una ejecución anterior (comprobando
  que el PID siga siendo rqbit antes de tocarlo).
- El magnet que reparte el addon se respeta tal cual, con sus `tr=`. Si el
  addon solo dio el hash, se construye el magnet con `dn` y se deja que DHT
  encuentre peers.
- Lo descargado queda en `Descargas/clubTivi` (o, si el sistema no expone esa
  carpeta, en el directorio de soporte de la app).

## Piezas

| Archivo | Papel |
| --- | --- |
| `lib/data/services/p2p/rqbit_models.dart` | Parseo de la API, magnet y elección de archivo (puro). |
| `lib/data/services/p2p/rqbit_client.dart` | Cliente HTTP delgado (`RqbitApi`) con errores tipados. |
| `lib/data/services/p2p/rqbit_supervisor.dart` | Ciclo de vida del proceso: puerto libre, readiness, reinicio, cierre, PID huérfano. |
| `lib/data/services/p2p/rqbit_binary.dart` | Localiza el binario y lo descarga verificado si falta. |
| `lib/data/services/p2p/rqbit_engine.dart` | Orquesta todo y devuelve la URL de streaming con progreso. |
| `lib/features/shows/p2p_progress_dialog.dart` | Espera visible (fases, porcentaje, cancelar) y errores legibles. |

La resolución de fuentes (`ShowsRepository.resolveStreams`) deja de marcar el
torrent como no disponible cuando hay motor P2P en la plataforma; si un debrid
falla al resolver, la reproducción cae al motor P2P como red de seguridad.

## Procedencia del binario y licencia

- Proyecto: [ikatson/rqbit](https://github.com/ikatson/rqbit), **Apache-2.0**
  (la licencia completa viaja en el paquete como `rqbit-LICENSE.txt`).
- Versión fijada: **v9.0.1**. Windows x64:
  `https://github.com/ikatson/rqbit/releases/download/v9.0.1/rqbit.exe`
  (12 706 816 bytes), SHA-256
  `2ed683203beca628e0c45f62f99feeef4242cecc3444c8422dfe5b1b6aa38cea`.
- `tools/package_windows.ps1` descarga el binario una vez a `tools/rqbit/`
  (ignorado por git), verifica el hash y lo copia junto a `clubtivi.exe`; el
  paquete sigue funcionando aunque la descarga falle (`-SkipRqbit` lo omite a
  propósito).
- Si el binario no está junto a la app, la app lo descarga bajo demanda a su
  caché verificando el mismo SHA-256. En macOS/Linux no hay URL fijada: se usa
  el binario que venga empaquetado y, si falta, el error lo explica.

## Probar

```sh
flutter test test/p2p                     # cliente, supervisor, motor, binario y UI
CLUBTIVI_RQBIT_BINARY=/ruta/a/rqbit dart run tools/rqbit_smoke.dart
```

`tools/rqbit_smoke.dart` arranca el motor de verdad, añade el magnet de prueba
que se le pase (por defecto, el de Sintel de WebTorrent), espera metadatos y
comprueba que el endpoint de streaming responde `206` con `Range`.

## Límites conocidos

- Android/iOS no pueden ejecutar el sidecar: en esas plataformas el torrent
  sigue mostrando el motivo de no disponibilidad.
- Un torrent sin seeders no llega a metadatos; el timeout (60 s) lo dice con un
  mensaje accionable.
- Si el proceso muere a mitad de reproducción, el supervisor lo reinicia para
  el siguiente Play, pero el stream en curso se corta.
