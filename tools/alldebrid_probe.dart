// Sonda del flujo magnet→URL de AllDebrid contra el API real.
//
// Necesita una clave propia en ALLDEBRID_APIKEY (Windows):
//   set ALLDEBRID_APIKEY=...   (Windows)
//   export ALLDEBRID_APIKEY=... (bash)
//   dart run tools/alldebrid_probe.dart "magnet:?xt=urn:btih:..."
//
// La apikey de demostración de https://docs.alldebrid.com/ no se incrusta:
// aunque es pública, el escáner de secretos la marca como credencial y no
// aporta nada al flujo real.
import 'dart:io';

import 'package:clubtivi/data/datasources/remote/debrid_client.dart';

Future<void> main(List<String> args) async {
  final key = Platform.environment['ALLDEBRID_APIKEY']?.trim() ?? '';
  if (key.isEmpty) {
    stderr.writeln('Falta ALLDEBRID_APIKEY.');
    stderr.writeln('Consigue una clave en https://docs.alldebrid.com/ y '
        'expórtala antes de ejecutar la sonda.');
    exitCode = 2;
    return;
  }

  final magnet = args.isNotEmpty
      ? args.first
      : 'magnet:?xt=urn:btih:842783e3005495d5d1637f5364b59343c7844707';

  final timeoutSeconds =
      int.tryParse(Platform.environment['ALLDEBRID_TIMEOUT'] ?? '') ?? 20;
  final service = AllDebridService(
    apiToken: key,
    resolveTimeout: Duration(seconds: timeoutSeconds),
  );

  stdout.writeln('verifyToken: ${await service.verifyToken()}');

  final sw = Stopwatch()..start();
  try {
    final resolved = await service.resolveFromMagnet(
      magnet,
      onProgress: (status, progress) {
        stdout.writeln('[${sw.elapsed.inSeconds}s] $status ($progress%)');
      },
    );
    stdout.writeln('RESUELTO en ${sw.elapsed.inSeconds}s:');
    stdout.writeln('  url: ${resolved?.url}');
    stdout.writeln('  fichero: ${resolved?.filename}');
  } catch (e) {
    stdout.writeln('FALLO en ${sw.elapsed.inSeconds}s: $e');
  }
}
