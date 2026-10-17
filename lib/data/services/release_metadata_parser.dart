/// Lectura de metadatos de un release (calidad, tamaño, seeds) y construcción
/// de magnets.
///
/// Lógica pura, sin Flutter ni red. La comparten el cliente de Torrentio y el
/// mapeo de addons Stremio para que ambos interpreten los títulos igual.
library;

/// `4K`, `1080p`, `720p`, `480p` o cadena vacía cuando no se declara.
///
/// Sin distinguir mayúsculas: los addons etiquetan igual `4k` que `4K` (el
/// nombre de Torrentio, por ejemplo, viene en minúsculas).
String qualityFromText(String text) {
  final value = text.toLowerCase();
  if (value.contains('2160p') || value.contains('4k')) return '4K';
  if (value.contains('1080p')) return '1080p';
  if (value.contains('720p')) return '720p';
  if (value.contains('480p')) return '480p';
  return '';
}

/// Primer `NN GB` / `NN MB` del texto, en bytes.
int? sizeBytesFromText(String text) {
  final match =
      RegExp(r'(\d+\.?\d*)\s*(GB|MB)', caseSensitive: false).firstMatch(text);
  if (match == null) return null;
  final value = double.tryParse(match.group(1)!) ?? 0;
  final unit = match.group(2)!.toLowerCase();
  final bytes = value * (unit == 'gb' ? 1024 * 1024 * 1024 : 1024 * 1024);
  return bytes.round();
}

/// Número de seeds del título (`👤 42`), o null si no viene.
int? seedsFromText(String text) {
  final match = RegExp(r'👤\s*(\d+)').firstMatch(text);
  if (match != null) return int.tryParse(match.group(1)!);
  return null;
}

/// Magnet con el `dn` del nombre y los trackers anunciados por el addon.
///
/// Los `sources` del protocolo Stremio pueden ser `tracker:<url>`,
/// `dht:<hash>` o URLs sueltas; solo se traducen los trackers, porque el resto
/// no aporta nada al magnet.
String buildMagnet({
  required String infoHash,
  required String name,
  Iterable<String> sources = const [],
}) {
  final buffer = StringBuffer('magnet:?xt=urn:btih:$infoHash');
  final encoded = Uri.encodeComponent(name);
  if (encoded.isNotEmpty) buffer.write('&dn=$encoded');
  for (final source in sources) {
    final tracker = _trackerUrl(source);
    if (tracker == null) continue;
    buffer
      ..write('&tr=')
      ..write(Uri.encodeComponent(tracker));
  }
  return buffer.toString();
}

String? _trackerUrl(String source) {
  final value = source.trim();
  if (value.isEmpty) return null;
  if (value.startsWith('dht:')) return null;
  if (value.startsWith('tracker:')) {
    final url = value.substring('tracker:'.length).trim();
    return url.isEmpty ? null : url;
  }
  return value.contains('://') ? value : null;
}
