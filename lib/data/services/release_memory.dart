import 'dart:async';

import '../datasources/local/playback_dao.dart';
import '../models/playback_request.dart';
import '../models/release_fingerprint.dart';
import '../models/stream_source.dart';
import '../repositories/shows_repository.dart';

/// Release recordado ya reabierto: la URL lista y el id con el que se guardó.
class ReopenedRelease {
  final String url;
  final String sourceId;
  final PlaybackSourceRow source;

  const ReopenedRelease({
    required this.url,
    required this.sourceId,
    required this.source,
  });
}

/// Memoria del release elegido por título.
///
/// Guarda la huella del fichero (proveedor + `infoHash`/`fileIdx` + calidad),
/// nunca la URL de debrid resuelta, y sabe reabrirla sin preguntar a los
/// addons. Un fallo suma en `fail_count`; tras [maxFailures] deja de ofrecerse,
/// pero la fila sigue ahí para poder elegirla a mano.
class ReleaseMemory {
  ReleaseMemory({required this.dao, this.maxFailures = 2});

  final PlaybackDao dao;

  /// Fallos seguidos a partir de los cuales el release deja de ofrecerse.
  final int maxFailures;

  /// Huella estable de una fuente, la que se guarda como `source_id`.
  static String sourceIdFor(StreamSource stream) => releaseSourceIdFrom(
        providerId: stream.providerId,
        infoHash: stream.infoHash,
        fileIdx: stream.fileIdx,
        quality: stream.quality,
        url: stream.url,
      );

  /// Recuerda con qué release se abrió [request].
  ///
  /// [posterUrl] viaja con la fila para que «continuar viendo» tenga carátula
  /// desde el primer minuto, no sólo cuando el grabador escriba progreso.
  Future<void> remember(
    PlaybackRequest request,
    StreamSource stream, {
    String? posterUrl,
  }) {
    return dao.recordSource(
      request,
      sourceId: sourceIdFor(stream),
      providerId: stream.providerId,
      infoHash: stream.infoHash,
      fileIdx: stream.fileIdx,
      quality: stream.quality,
      sizeBytes: stream.sizeBytes,
      posterUrl: posterUrl,
    );
  }

  /// El release que todavía merece ofrecerse para este título, si lo hay.
  Future<PlaybackSourceRow?> recall(String mediaKey) =>
      dao.rememberedSource(mediaKey, maxFailures: maxFailures);

  /// Intenta reabrir el release recordado sin buscar en addons.
  ///
  /// Devuelve null cuando no hay nada recordado, cuando el release guardado no
  /// tenía torrent (un enlace directo no se puede reabrir por hash) o cuando el
  /// debrid ya no lo sirve; en ese último caso apunta el fallo y la búsqueda
  /// normal sigue su curso.
  ///
  /// Está acotado en el tiempo: la memoria es un atajo, no un peaje. Si la base
  /// o el debrid tardan más de [timeout], se arranca la búsqueda normal.
  Future<ReopenedRelease?> reopen(
    ShowsRepository repo, {
    required String mediaKey,
    int? season,
    int? episode,
    void Function(String status, int progress)? onProgress,
    Duration timeout = const Duration(seconds: 1),
  }) async {
    if (!repo.hasDebrid) return null;
    try {
      return await _reopen(
        repo,
        mediaKey: mediaKey,
        season: season,
        episode: episode,
        onProgress: onProgress,
      ).timeout(timeout);
    } on TimeoutException {
      return null;
    }
  }

  Future<ReopenedRelease?> _reopen(
    ShowsRepository repo, {
    required String mediaKey,
    int? season,
    int? episode,
    void Function(String status, int progress)? onProgress,
  }) async {
    PlaybackSourceRow? source;
    try {
      source = await recall(mediaKey);
    } catch (_) {
      // La memoria es un atajo, nunca un requisito: si la base no responde,
      // la reproducción sigue por el camino normal.
      return null;
    }
    final hash = source?.infoHash;
    if (source == null || hash == null || hash.isEmpty) return null;
    try {
      final resolved = await repo.resolveTorrentHash(
        hash,
        fileIdx: source.fileIdx,
        season: season,
        episode: episode,
        onProgress: onProgress,
      );
      if (resolved == null || resolved.url.isEmpty) {
        await dao.markSourceFailed(mediaKey, source.sourceId);
        return null;
      }
      return ReopenedRelease(
        url: resolved.url,
        sourceId: source.sourceId,
        source: source,
      );
    } catch (_) {
      await dao.markSourceFailed(mediaKey, source.sourceId);
      return null;
    }
  }
}
