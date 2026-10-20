// Sonda del flujo magnet→URL de AllDebrid contra el API real.
//
// Sin argumentos usa la apikey pública de demostración de
// https://docs.alldebrid.com/, que devuelve datos estáticos: sirve para
// comprobar endpoints, forma de las respuestas y que el progreso ya no sea un
// 50 % fijo.
//
// Con una cuenta real:
//   set ALLDEBRID_APIKEY=...   (Windows)
//   export ALLDEBRID_APIKEY=... (bash)
//   dart run tools/alldebrid_probe.dart "magnet:?xt=urn:btih:..."
import 'dart:io';

import 'package:clubtivi/data/datasources/remote/debrid_client.dart';

Future<void> main(List<String> args) async {
  final key =
      Platform.environment['ALLDEBRID_APIKEY']?.trim().isNotEmpty == true
          ? Platform.environment['ALLDEBRID_APIKEY']!.trim()
          : 'staticDemoApikeyPrem';
  final magnet = args.isNotEmpty
      ? args.first
      : 'magnet:?xt=urn:btih:842783e3005495d5d1637f5364b59343c7844707';

  final timeoutSeconds =
      int.tryParse(Platform.environment['ALLDEBRID_TIMEOUT'] ?? '') ?? 20;
  final service = AllDebridService(
    apiToken: key,
    resolveTimeout: Duration(seconds: timeoutSeconds),
  );

  stdout.writeln('key: ${key == 'staticDemoApikeyPrem' ? 'demo' : 'propia'}');
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
