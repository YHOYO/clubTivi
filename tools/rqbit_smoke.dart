/// Humo real del motor P2P, sin Flutter: arranca rqbit de verdad, añade un
/// magnet público, espera los metadatos y comprueba que el endpoint de
/// streaming responde `206` a una petición con `Range`.
///
/// Uso:
///
///     CLUBTIVI_RQBIT_BINARY=/ruta/a/rqbit dart run tools/rqbit_smoke.dart
///     dart run tools/rqbit_smoke.dart 'magnet:?xt=urn:btih:...' [fileIndex]
///
/// Sin `CLUBTIVI_RQBIT_BINARY`, rqbit se busca junto a la app, en la caché del
/// proyecto o se descarga de la release verificada (Windows). Es una prueba
/// manual: necesita red y peers reales, por eso no forma parte de la suite.
library;

import 'dart:io';

import 'package:clubtivi/data/services/p2p/rqbit_binary.dart';
import 'package:clubtivi/data/services/p2p/rqbit_engine.dart';
import 'package:clubtivi/data/services/p2p/rqbit_models.dart';
import 'package:clubtivi/data/services/p2p/rqbit_supervisor.dart';

/// Sintel (WebTorrent) con trackers públicos: torrent pequeño y bien sembrado.
const _defaultMagnet =
    'magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10'
    '&dn=Sintel'
    '&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce'
    '&tr=udp%3A%2F%2Fexplodie.org%3A6969%2Fannounce';

Future<void> main(List<String> arguments) async {
  final magnet = arguments.isNotEmpty ? arguments.first : _defaultMagnet;
  final fileIndex = arguments.length > 1 ? int.tryParse(arguments[1]) : 5;
  final hash = RegExp(r'btih:([A-Fa-f0-9]{40})').firstMatch(magnet)?.group(1);
  if (hash == null) {
    stderr.writeln('El magnet no tiene un infoHash de 40 hex.');
    exitCode = 2;
    return;
  }

  final root = Directory('.cache/rqbit-smoke');
  await root.create(recursive: true);
  final downloads = '${root.path}${Platform.pathSeparator}downloads';
  final session = '${root.path}${Platform.pathSeparator}session';

  final engine = RqbitEngine(
    supervisor: RqbitSupervisor(
      downloadDirectory: downloads,
      stateDirectory: session,
      onLog: (line) => stdout.writeln('[rqbit] $line'),
    ),
    binary: RqbitBinary(
      cacheDirectory: Directory('.cache/rqbit-engine'),
      executableDirectory: File(Platform.resolvedExecutable).parent.path,
    ),
    outputDirectory: downloads,
    metadataTimeout: const Duration(seconds: 120),
  );

  try {
    stdout.writeln('Preparando $hash …');
    final playback = await engine.prepare(
      P2pStreamRequest(
        infoHash: hash,
        magnetUrl: magnet,
        fileIndex: fileIndex,
      ),
      onProgress: (progress) => stdout.writeln('· ${progress.message}'),
    );
    stdout.writeln('Stream: ${playback.streamUrl}');
    stdout.writeln('Archivo: ${playback.fileName}');

    final client = HttpClient();
    final request = await client.getUrl(playback.streamUrl);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-65535');
    final response = await request.close();
    final bytes = await response.fold<int>(0, (sum, chunk) => sum + chunk.length);
    client.close(force: true);

    stdout.writeln(
      'HTTP ${response.statusCode} '
      'content-range=${response.headers.value(HttpHeaders.contentRangeHeader)} '
      'bytes=$bytes',
    );
    if (response.statusCode != HttpStatus.partialContent || bytes == 0) {
      stderr.writeln('El endpoint de streaming no respondió 206 con datos.');
      exitCode = 1;
    } else {
      stdout.writeln('OK: streaming P2P verificado con rqbit real.');
    }
  } catch (error) {
    stderr.writeln('Fallo el humo P2P: $error');
    exitCode = 1;
  } finally {
    await engine.dispose();
  }
}
