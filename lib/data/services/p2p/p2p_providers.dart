import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'rqbit_binary.dart';
import 'rqbit_engine.dart';
import 'rqbit_supervisor.dart';

/// Un único motor para toda la app.
///
/// La carpeta de descargas es `Downloads/clubTivi` para que lo descargado sea
/// visible; si el sistema no expone Downloads, se usa la de soporte de la app.
/// El estado del motor (sesión de rqbit y PID) vive en soporte de la app.
final rqbitEngineProvider = FutureProvider<RqbitEngine>((ref) async {
  final support = await getApplicationSupportDirectory();
  Directory? downloads;
  try {
    downloads = await getDownloadsDirectory();
  } catch (error) {
    debugPrint('[P2P] Downloads folder unavailable: $error');
  }

  final base = Directory(p.join(support.path, 'p2p'));
  await base.create(recursive: true);
  final downloadDirectory = p.join((downloads ?? support).path, 'clubTivi');

  final binary = RqbitBinary(
    cacheDirectory: Directory(p.join(base.path, 'engine')),
    executableDirectory: File(Platform.resolvedExecutable).parent.path,
  );
  final supervisor = RqbitSupervisor(
    downloadDirectory: downloadDirectory,
    stateDirectory: p.join(base.path, 'session'),
    onLog: (line) => debugPrint('[P2P] $line'),
  );
  final engine = RqbitEngine(
    supervisor: supervisor,
    binary: binary,
    outputDirectory: downloadDirectory,
  );
  ref.onDispose(() {
    unawaited(engine.dispose());
  });
  return engine;
});
