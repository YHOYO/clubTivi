/// Traducción de los streams de un addon Stremio a [StreamSource].
///
/// Lógica pura: recibe el JSON ya decodificado de `/stream/...` y no toca red
/// ni almacenamiento. Respeta las dos formas reproducibles del protocolo —`url`
/// directa e `infoHash` con `fileIdx`/`sources`— y traslada `behaviorHints`
/// (cabeceras, `notWebReady`, `proxyHeaders`, `filename`, `videoSize`) y los
/// `subtitles` referenciados sin perderlos por el camino.
library;

import '../models/language_preferences.dart';
import '../models/stream_source.dart';
import 'release_language_parser.dart';
import 'release_metadata_parser.dart';

/// Convierte un stream del addon, o devuelve null cuando no es reproducible:
/// `ytId` y `externalUrl` quedan fuera porque este reproductor no sabe abrir un
/// vídeo de YouTube ni una redirección a otra plataforma.
StreamSource? stremioStreamToSource(
  Map<String, dynamic> stream, {
  required String providerId,
  required String providerName,
  required int index,
}) {
  final url = _string(stream['url']);
  final infoHash = _string(stream['infoHash']);
  if ((url == null || url.isEmpty) && (infoHash == null || infoHash.isEmpty)) {
    return null;
  }

  final name = _string(stream['name']) ?? '';
  final title = _string(stream['title']) ?? '';
  final behaviorHints = stream['behaviorHints'];
  final hints = behaviorHints is Map ? behaviorHints : const {};

  final filename = _string(hints['filename']);
  final headers = _headersFromHints(hints);
  final subtitles = _subtitlesFrom(stream['subtitles']);
  final searchText = [name, title, filename ?? ''].join(' ');
  final languages = ReleaseLanguageParser.parse(searchText);
  final videoSize = _int(hints['videoSize']);

  final displayTitle = title.isNotEmpty
      ? title
      : (filename != null && filename.isNotEmpty ? filename : name);

  final quality = qualityFromText(searchText);
  final sizeBytes = videoSize ?? sizeBytesFromText(searchText);

  if (url != null && url.isNotEmpty) {
    return StreamSource(
      id: '$providerId:url:$index',
      providerId: providerId,
      providerName: providerName,
      kind: SourceKind.addon,
      title: displayTitle,
      url: url,
      quality: quality.isEmpty ? null : quality,
      sizeBytes: sizeBytes,
      seeds: seedsFromText(title),
      audioLanguages: languages.audio,
      subtitleLanguages: languages.subtitles,
      subtitles: subtitles,
      headers: headers,
      referer: _referer(headers),
      needsProxy: hints['notWebReady'] == true || headers.isNotEmpty,
    );
  }

  final hash = infoHash!;
  final fileIdx = _int(stream['fileIdx']);
  final sources = _stringList(stream['sources']);
  return StreamSource(
    id: '$providerId:${hash.toLowerCase()}:${fileIdx ?? 0}',
    providerId: providerId,
    providerName: providerName,
    kind: SourceKind.torrent,
    title: displayTitle,
    infoHash: hash,
    fileIdx: fileIdx,
    magnetUrl: buildMagnet(
      infoHash: hash,
      name: filename?.isNotEmpty == true ? filename! : (name.isNotEmpty ? name : displayTitle),
      sources: sources,
    ),
    quality: quality.isEmpty ? null : quality,
    sizeBytes: sizeBytes,
    seeds: seedsFromText(title),
    audioLanguages: languages.audio,
    subtitleLanguages: languages.subtitles,
    subtitles: subtitles,
    headers: headers,
    referer: _referer(headers),
    needsProxy: hints['notWebReady'] == true,
  );
}

/// `proxyHeaders.request` del protocolo: cabeceras que hay que enviar al CDN.
Map<String, String> _headersFromHints(Map<dynamic, dynamic> hints) {
  final proxyHeaders = hints['proxyHeaders'];
  if (proxyHeaders is! Map) return const {};
  final request = proxyHeaders['request'];
  if (request is! Map) return const {};

  final headers = <String, String>{};
  for (final entry in request.entries) {
    final key = entry.key;
    final value = entry.value;
    if (key is String && value is String && key.isNotEmpty) {
      headers[key] = value;
    }
  }
  return headers;
}

String? _referer(Map<String, String> headers) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'referer') return entry.value;
  }
  return null;
}

List<SubtitleReference> _subtitlesFrom(Object? value) {
  if (value is! List) return const [];
  final subtitles = <SubtitleReference>[];
  for (final entry in value) {
    if (entry is! Map) continue;
    final url = _string(entry['url']);
    if (url == null || url.isEmpty) continue;
    final id = _string(entry['id']) ?? url;
    final lang = _string(entry['lang']) ?? '';
    subtitles.add(SubtitleReference(
      id: id,
      url: url,
      language: normalizeLanguageCode(lang) ?? lang,
      label: lang.isEmpty ? null : lang,
    ));
  }
  return subtitles;
}

String? _string(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return [
    for (final entry in value)
      if (entry is String && entry.isNotEmpty) entry,
  ];
}
