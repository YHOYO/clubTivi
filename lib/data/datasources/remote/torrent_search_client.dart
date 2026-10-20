import 'package:dio/dio.dart';

import '../../models/stream_source.dart';
import '../../services/stremio_stream_mapper.dart';

/// Searches for torrent hashes by IMDB ID using the Torrentio addon API
/// Torrentio is a Stremio addon that aggregates torrent sources
/// This only uses the public addon API (no Stremio dependency)
///
/// Devuelve ya el tipo de dominio de la app: `StreamSource` con kind
/// [SourceKind.torrent], idiomas detectados en el nombre del release y el
/// magnet listo para que lo resuelva un debrid o el futuro motor P2P.
///
/// El mapeo no se duplica aquí: usa [stremioStreamToSource], el mismo que
/// traduce los addons instalados, para que una fila de Torrentio diga lo mismo
/// que una de Comet o de un addon de anime.
class TorrentSearchClient {
  final Dio _dio;

  static const _torrentioBase = 'https://torrentio.strem.fun';

  TorrentSearchClient({Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options
      ..connectTimeout = const Duration(seconds: 10)
      ..receiveTimeout = const Duration(seconds: 15);
  }

  /// Search for streams by IMDB ID (for movies)
  Future<List<StreamSource>> searchMovie(String imdbId) async {
    return _search('movie', imdbId);
  }

  /// Search for streams by IMDB ID + season + episode (for TV shows)
  Future<List<StreamSource>> searchEpisode(
    String imdbId, {
    required int season,
    required int episode,
  }) async {
    return _search('series', '$imdbId:$season:$episode');
  }

  Future<List<StreamSource>> _search(String type, String id) async {
    try {
      final response = await _dio.get('$_torrentioBase/stream/$type/$id.json');
      final data = response.data as Map<String, dynamic>;
      final streams = data['streams'] as List? ?? [];

      final sources = <StreamSource>[];
      for (var i = 0; i < streams.length; i++) {
        final entry = streams[i];
        if (entry is! Map) continue;
        final source = stremioStreamToSource(
          Map<String, dynamic>.from(entry),
          providerId: 'torrentio',
          providerName: 'Torrentio',
          index: i,
        );
        // Este cliente sólo aporta torrents; una URL HTTP de Torrentio no es
        // su responsabilidad (los addons ya la traen como fuente directa).
        if (source != null && source.kind == SourceKind.torrent) {
          sources.add(source);
        }
      }
      return sources;
    } catch (e) {
      // Torrentio may be unavailable; return empty list
      return [];
    }
  }
}
