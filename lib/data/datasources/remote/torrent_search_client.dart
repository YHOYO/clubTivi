import 'package:dio/dio.dart';

import '../../models/stream_source.dart';
import '../../services/release_language_parser.dart';

/// Searches for torrent hashes by IMDB ID using the Torrentio addon API
/// Torrentio is a Stremio addon that aggregates torrent sources
/// This only uses the public addon API (no Stremio dependency)
///
/// Devuelve ya el tipo de dominio de la app: `StreamSource` con kind
/// [SourceKind.torrent], idiomas detectados en el nombre del release y el
/// magnet listo para que lo resuelva un debrid o el futuro motor P2P.
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
      for (final entry in streams) {
        if (entry is! Map<String, dynamic>) continue;
        final source = _mapStream(entry);
        if (source != null) sources.add(source);
      }
      return sources;
    } catch (e) {
      // Torrentio may be unavailable; return empty list
      return [];
    }
  }

  /// Convierte un stream de Torrentio en la fuente unificada. Devuelve null si
  /// no trae un infoHash, que es lo único que este cliente sabe resolver.
  StreamSource? _mapStream(Map<String, dynamic> stream) {
    final title = stream['title'] as String? ?? '';
    final name = stream['name'] as String? ?? '';

    // Extract info hash from the infoHash field or magnet URL
    String? infoHash = stream['infoHash'] as String?;
    if (infoHash == null) {
      final url = stream['url'] as String? ?? '';
      final hashMatch = RegExp(r'btih:([a-fA-F0-9]{40})').firstMatch(url);
      infoHash = hashMatch?.group(1);
    }
    if (infoHash == null || infoHash.isEmpty) return null;

    final fileIdx = stream['fileIdx'] as int?;
    final displayTitle = title.isNotEmpty ? title : name;
    final searchText = '$name $title';
    // Torrentio ya trae el nombre del release en `title`; `name` aporta la
    // calidad cuando el título viene vacío.
    final quality = _extractQuality(title.isNotEmpty ? title : name);
    final languages = ReleaseLanguageParser.parse(searchText);

    return StreamSource(
      id: 'torrentio:${infoHash.toLowerCase()}:${fileIdx ?? 0}',
      providerId: 'torrentio',
      providerName: 'torrent',
      kind: SourceKind.torrent,
      title: displayTitle,
      infoHash: infoHash,
      fileIdx: fileIdx,
      magnetUrl: _buildMagnet(infoHash, name.isNotEmpty ? name : displayTitle),
      quality: quality.isEmpty ? null : quality,
      sizeBytes: _extractSizeBytes(searchText),
      seeds: _extractSeeds(title),
      audioLanguages: languages.audio,
      subtitleLanguages: languages.subtitles,
    );
  }

  String _extractQuality(String title) {
    if (title.contains('2160p') || title.contains('4K')) return '4K';
    if (title.contains('1080p')) return '1080p';
    if (title.contains('720p')) return '720p';
    if (title.contains('480p')) return '480p';
    return '';
  }

  int? _extractSizeBytes(String text) {
    final match =
        RegExp(r'(\d+\.?\d*)\s*(GB|MB)', caseSensitive: false).firstMatch(text);
    if (match == null) return null;
    final value = double.tryParse(match.group(1)!) ?? 0;
    final unit = match.group(2)!.toLowerCase();
    final bytes = value * (unit == 'gb' ? 1024 * 1024 * 1024 : 1024 * 1024);
    return bytes.round();
  }

  int? _extractSeeds(String title) {
    final match = RegExp(r'👤\s*(\d+)').firstMatch(title);
    if (match != null) return int.tryParse(match.group(1)!);
    return null;
  }

  String _buildMagnet(String hash, String name) {
    final encoded = Uri.encodeComponent(name);
    return 'magnet:?xt=urn:btih:$hash&dn=$encoded';
  }
}
