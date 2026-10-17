/// Motor P2P de la app: convierte una fuente con `infoHash` en una URL local
/// reproducible.
///
/// Orquesta el binario, el supervisor y el cliente, y expone un progreso
/// legible para la UI. No bloquea el hilo de UI: todo es asíncrono y cada
/// espera tiene un límite con un error tipado.
library;

import 'dart:async';
import 'dart:io';

import 'rqbit_binary.dart';
import 'rqbit_client.dart';
import 'rqbit_models.dart';
import 'rqbit_supervisor.dart';

/// Fases visibles del arranque, en orden.
enum P2pPhase {
  locatingEngine,
  downloadingEngine,
  startingEngine,
  addingTorrent,
  waitingMetadata,
  ready,
}

class P2pProgress {
  final P2pPhase phase;
  final String message;

  /// 0..1 cuando se conoce el tamaño; null si es indeterminado.
  final double? fraction;

  const P2pProgress(this.phase, this.message, {this.fraction});

  @override
  String toString() => 'P2pProgress(${phase.name}, $message, $fraction)';
}

/// Resultado reproducible: la URL local que el reproductor abrirá.
class P2pPlayback {
  final Uri streamUrl;
  final int fileIndex;
  final String fileName;
  final String torrentId;

  const P2pPlayback({
    required this.streamUrl,
    required this.fileIndex,
    required this.fileName,
    required this.torrentId,
  });

  @override
  String toString() => 'P2pPlayback($streamUrl, file $fileIndex)';
}

/// Construye el cliente para la URL base que acaba de arrancar el supervisor.
typedef RqbitApiFactory = RqbitApi Function(Uri baseUri);

/// Un solo motor por app: comparte proceso, cliente y torrents ya añadidos.
class RqbitEngine {
  final RqbitSupervisor supervisor;
  final RqbitBinary binary;
  final RqbitApiFactory _apiFactory;

  /// Carpeta de descargas que se pasa a rqbit.
  final String outputDirectory;

  final Duration metadataTimeout;

  /// Espera a que rqbit pase de `initializing` a `live`. Mientras valida
  /// archivos, su endpoint de streaming responde 500, así que no se puede
  /// devolver la URL antes.
  final Duration readinessTimeout;
  final Duration pollInterval;

  RqbitApi? _api;
  Uri? _apiBase;
  final Map<String, String> _torrentIds = {};
  bool _disposed = false;

  RqbitEngine({
    required this.supervisor,
    required this.binary,
    required this.outputDirectory,
    RqbitApiFactory? apiFactory,
    this.metadataTimeout = const Duration(seconds: 60),
    this.readinessTimeout = const Duration(seconds: 45),
    this.pollInterval = const Duration(milliseconds: 500),
  }) : _apiFactory = apiFactory ?? ((baseUri) => RqbitClient(baseUri: baseUri));

  /// Prepara la reproducción y devuelve la URL de streaming.
  ///
  /// Las reproducciones del mismo torrent reutilizan el id ya añadido: no se
  /// duplica el torrent ni se vuelve a pedir metadata.
  Future<P2pPlayback> prepare(
    P2pStreamRequest request, {
    void Function(P2pProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (_disposed) {
      throw const RqbitException('The P2P engine is already closed');
    }
    _report(onProgress, P2pPhase.locatingEngine, 'Looking for the P2P engine…');

    final location = await binary.ensureAvailable(
      onProgress: (progress) {
        _report(
          onProgress,
          P2pPhase.downloadingEngine,
          progress.totalBytes == null
              ? 'Downloading the P2P engine…'
              : 'Downloading the P2P engine… '
                    '${_mb(progress.receivedBytes)} of ${_mb(progress.totalBytes!)} MB',
          fraction: progress.fraction,
        );
      },
    );

    _checkCancelled(isCancelled);
    _report(onProgress, P2pPhase.startingEngine, 'Starting the P2P engine…');
    final baseUri = await supervisor.ensureRunning(location.path);
    _checkCancelled(isCancelled);

    final api = _apiFor(baseUri);
    final infoHash = request.infoHash.trim().toLowerCase();

    String? torrentId = _torrentIds[infoHash];
    RqbitTorrentDetails? details;
    if (torrentId != null) {
      try {
        details = await api.torrent(torrentId);
      } on RqbitException {
        // La sesión de rqbit pudo perderlo: se vuelve a añadir.
        _torrentIds.remove(infoHash);
        torrentId = null;
        details = null;
      }
    }

    if (torrentId == null) {
      _report(onProgress, P2pPhase.addingTorrent, 'Adding torrent…');
      final added = await api.addTorrent(
        request.magnet,
        outputFolder: outputDirectory,
        // Sin esto, volver a reproducir un torrent cuyos archivos quedaron en
        // la carpeta de descargas falla: rqbit no sobrescribe por defecto.
        overwrite: true,
      );
      // Sin id no se puede consultar; el hash funciona como identificador.
      torrentId = added.id == null ? request.infoHash : '${added.id}';
      _torrentIds[infoHash] = torrentId;
      details = added.details;
    }

    final id = torrentId;

    _report(
      onProgress,
      P2pPhase.waitingMetadata,
      'Waiting for torrent metadata…',
    );
    details = await _waitForMetadata(
      api,
      id,
      details,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
    await _waitUntilPlayable(
      api,
      id,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );

    final fileIndex = selectTorrentFileIndex(details.files, request.fileIndex);
    final file = details.files[fileIndex];
    final streamUrl = api.streamUrl(id, fileIndex);
    _report(onProgress, P2pPhase.ready, 'Starting playback…', fraction: 1);
    return P2pPlayback(
      streamUrl: streamUrl,
      fileIndex: fileIndex,
      fileName: file.name,
      torrentId: torrentId,
    );
  }

  Future<RqbitTorrentDetails> _waitForMetadata(
    RqbitApi api,
    String torrentId,
    RqbitTorrentDetails? details, {
    void Function(P2pProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final deadline = DateTime.now().add(metadataTimeout);
    var current = details;
    while (current == null || !current.hasMetadata) {
      _checkCancelled(isCancelled);
      if (DateTime.now().isAfter(deadline)) {
        throw RqbitMetadataTimeoutException(
          'No metadata for this torrent after ${metadataTimeout.inSeconds}s. '
          'It may have no seeders left; try another source.',
        );
      }
      await Future<void>.delayed(pollInterval);
      _checkCancelled(isCancelled);

      current = await api.torrent(torrentId);
      final stats = await _statsOrNull(api, torrentId);
      final torrentError = stats?.error;
      if (torrentError != null && torrentError.isNotEmpty) {
        throw RqbitTorrentErrorException(torrentError);
      }
      if (stats?.state == 'error') {
        throw RqbitTorrentErrorException(
          'The P2P engine reported an error for this torrent',
        );
      }
      _report(
        onProgress,
        P2pPhase.waitingMetadata,
        current.hasMetadata
            ? 'Found ${current.files.length} files in ${current.name}'
            : 'Searching for peers…',
        fraction: stats?.progress,
      );
    }
    return current;
  }

  /// El stream solo responde cuando el torrent deja de estar `initializing`
  /// (validación de archivos existentes) y está `live`.
  Future<void> _waitUntilPlayable(
    RqbitApi api,
    String torrentId, {
    void Function(P2pProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final deadline = DateTime.now().add(readinessTimeout);
    while (true) {
      _checkCancelled(isCancelled);
      final stats = await _statsOrNull(api, torrentId);
      final error = stats?.error;
      if (error != null && error.isNotEmpty) {
        throw RqbitTorrentErrorException(error);
      }
      final state = stats?.state;
      if (state == 'error') {
        throw RqbitTorrentErrorException(
          'The P2P engine reported an error for this torrent',
        );
      }
      if (state == null || state == 'live' || state == 'finished') {
        return;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw RqbitTorrentNotReadyException(
          'The torrent stayed in "$state" for '
          '${readinessTimeout.inSeconds}s. Try another source.',
        );
      }
      _report(
        onProgress,
        P2pPhase.startingEngine,
        state == 'initializing'
            ? 'Checking the torrent files…'
            : 'Preparing the torrent…',
        fraction: stats?.progress,
      );
      await Future<void>.delayed(pollInterval);
    }
  }

  Future<RqbitTorrentStats?> _statsOrNull(RqbitApi api, String id) async {
    try {
      return await api.stats(id);
    } on RqbitHttpException catch (error) {
      if (error.isNotFound) rethrow;
      return null;
    }
  }

  RqbitApi _apiFor(Uri baseUri) {
    final cached = _api;
    if (cached != null && _apiBase == baseUri) return cached;
    _apiBase = baseUri;
    return _api = _apiFactory(baseUri);
  }

  void _report(
    void Function(P2pProgress progress)? onProgress,
    P2pPhase phase,
    String message, {
    double? fraction,
  }) {
    onProgress?.call(P2pProgress(phase, message, fraction: fraction));
  }

  void _checkCancelled(bool Function()? isCancelled) {
    if (isCancelled?.call() ?? false) throw const P2pCancelledException();
  }

  String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

  // ─── Estado y control desde Ajustes ─────────────────────────────────────

  bool get isRunning => supervisor.isRunning;

  Uri? get baseUri => supervisor.baseUri;

  /// Carpeta donde rqbit escribe lo descargado.
  String get downloadDirectory => outputDirectory;

  /// Carpeta de sesión/persistencia de rqbit.
  String get sessionDirectory => supervisor.stateDirectory;

  /// Torrents de la sesión, con estadísticas. Sin motor arrancado no hay nada
  /// que listar; un fallo del motor devuelve lista vacía en vez de romper la
  /// pantalla de ajustes.
  Future<List<RqbitTorrentDetails>> listTorrents() async {
    final api = _api;
    if (api == null || !supervisor.isRunning) return const [];
    try {
      return await api.listTorrents();
    } on RqbitException {
      return const [];
    }
  }

  /// Saca un torrent de la sesión. Con [deleteFiles] borra también lo
  /// descargado; sin él, los archivos quedan en la carpeta de descargas.
  Future<void> removeTorrent(String idOrHash, {bool deleteFiles = false}) async {
    final api = _api;
    if (api == null) return;
    if (deleteFiles) {
      await api.deleteTorrent(idOrHash);
    } else {
      await api.forgetTorrent(idOrHash);
    }
    _torrentIds.removeWhere((_, id) => id == idOrHash);
  }

  /// Para el motor sin cerrarlo: el siguiente Play lo vuelve a arrancar.
  Future<void> stop() async {
    await supervisor.stop();
    _api = null;
    _apiBase = null;
    _torrentIds.clear();
  }

  /// Vacía la sesión: olvida los torrents, para el motor y borra su estado
  /// persistido. Lo descargado se queda en la carpeta de descargas.
  Future<void> clearSession() async {
    try {
      for (final torrent in await listTorrents()) {
        final id = torrent.id;
        if (id != null) await _api?.forgetTorrent('$id');
      }
    } on RqbitException {
      // Si el motor no responde, el borrado de la sesión de abajo lo limpia
      // todo igualmente.
    }
    await stop();
    final directory = Directory(supervisor.stateDirectory);
    if (await directory.exists()) {
      try {
        await directory.delete(recursive: true);
      } catch (_) {
        // Un estado que no se puede borrar no debe tumbar la pantalla; el
        // motor lo recrea al arrancar.
      }
    }
    _torrentIds.clear();
  }

  /// Cierra el motor y mata el proceso. Seguro de llamar más de una vez.
  ///
  /// Es definitivo: después de esto el supervisor ya no arranca nada. Se usa
  /// al cerrar la app y al recrear el motor por un cambio de ajustes.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _api = null;
    _apiBase = null;
    _torrentIds.clear();
    await supervisor.dispose();
  }
}

/// El usuario canceló la espera.
class P2pCancelledException implements Exception {
  const P2pCancelledException();

  @override
  String toString() => 'P2P playback cancelled';
}

class RqbitMetadataTimeoutException extends RqbitException {
  const RqbitMetadataTimeoutException(super.message);
}

class RqbitTorrentErrorException extends RqbitException {
  const RqbitTorrentErrorException(super.message);
}

class RqbitTorrentNotReadyException extends RqbitException {
  const RqbitTorrentNotReadyException(super.message);
}
