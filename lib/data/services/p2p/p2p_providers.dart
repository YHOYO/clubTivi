import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'p2p_settings.dart';
import 'rqbit_binary.dart';
import 'rqbit_engine.dart';
import 'rqbit_supervisor.dart';

/// Carpeta base de la app para el motor (caché del binario y sesión de rqbit).
final p2pBaseDirectoryProvider = FutureProvider<Directory>((ref) async {
  final support = await getApplicationSupportDirectory();
  final base = Directory(p.join(support.path, 'p2p'));
  await base.create(recursive: true);
  return base;
});

/// Carpeta por defecto de descargas: `Downloads/clubTivi`, con la de soporte
/// como red de seguridad en sistemas que no exponen Downloads.
final p2pDefaultDownloadDirectoryProvider = FutureProvider<String>(
  (ref) async {
    final support = await getApplicationSupportDirectory();
    Directory? downloads;
    try {
      downloads = await getDownloadsDirectory();
    } catch (error) {
      debugPrint('[P2P] Downloads folder unavailable: $error');
    }
    return p.join((downloads ?? support).path, 'clubTivi');
  },
);

/// Binario configurado para esta instalación: junto a la app o en su caché.
final p2pBinaryProvider = FutureProvider<RqbitBinary>((ref) async {
  final base = await ref.watch(p2pBaseDirectoryProvider.future);
  return RqbitBinary(
    cacheDirectory: Directory(p.join(base.path, 'engine')),
    executableDirectory: File(Platform.resolvedExecutable).parent.path,
  );
});

/// Dónde está (o no) el binario, sin descargar nada: es el estado que enseña
/// la pantalla de ajustes.
final p2pBinaryLocationProvider =
    FutureProvider<RqbitBinaryLocation?>((ref) async {
  final binary = await ref.watch(p2pBinaryProvider.future);
  return binary.locate();
});

/// Un único motor para toda la app, recreado cuando cambian los ajustes.
///
/// La carpeta de descargas y los límites se resuelven aquí; el supervisor los
/// recibe ya listos. Cambiar cualquier ajuste recrea el motor (y mata el
/// proceso anterior) para que los valores nuevos se apliquen de verdad.
final rqbitEngineProvider = FutureProvider<RqbitEngine>((ref) async {
  final settings = ref.watch(p2pSettingsProvider);
  final base = await ref.watch(p2pBaseDirectoryProvider.future);
  final binary = await ref.watch(p2pBinaryProvider.future);
  final downloadDirectory = settings.hasCustomDownloadDirectory
      ? settings.downloadDirectory!
      : await ref.watch(p2pDefaultDownloadDirectoryProvider.future);

  final supervisor = RqbitSupervisor(
    downloadDirectory: downloadDirectory,
    stateDirectory: p.join(base.path, 'session'),
    preferredPort: settings.port,
    downloadLimitBytesPerSecond: settings.downloadLimitBytesPerSecond,
    uploadLimitBytesPerSecond: settings.uploadLimitBytesPerSecond,
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
