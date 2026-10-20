/// Lectura de metadatos de un release (calidad, tamaño, seeds) y construcción
/// de magnets.
///
/// Lógica pura, sin Flutter ni red. La comparten el cliente de Torrentio y el
/// mapeo de addons Stremio para que ambos interpreten los títulos igual.
library;

/// `4K`, `1080p`, `720p`, `480p` o cadena vacía cuando no se declara.
///
/// Sin distinguir mayúsculas, pero con límites de palabra: `Wolfmax4k` es el
/// nombre de un tracker, no una resolución 4K. Los addons etiquetan igual
/// `4k` que `4K` (el nombre de Torrentio, por ejemplo, viene en minúsculas).
String qualityFromText(String text) {
  final value = text.toLowerCase();
  if (RegExp(r'\b(2160p|4k)\b').hasMatch(value)) return '4K';
  if (RegExp(r'\b1080p\b').hasMatch(value)) return '1080p';
  if (RegExp(r'\b720p\b').hasMatch(value)) return '720p';
  if (RegExp(r'\b480p\b').hasMatch(value)) return '480p';
  return '';
}

/// Codec, HDR y fuente del release, para la segunda línea del selector.
///
/// Devuelve una cadena vacía cuando el addon no declara nada; nunca inventa
/// `SDR` ni un codec por defecto.
String qualityDetailFromText(String text) {
  final value = text.toLowerCase();
  final parts = <String>[];

  if (RegExp(r'\b(h\.?265|hevc|x265)\b').hasMatch(value)) {
    parts.add('HEVC');
  } else if (RegExp(r'\b(h\.?264|avc|x264)\b').hasMatch(value)) {
    parts.add('H.264');
  } else if (RegExp(r'\bav1\b').hasMatch(value)) {
    parts.add('AV1');
  } else if (RegExp(r'\bxvid\b').hasMatch(value)) {
    parts.add('XviD');
  }

  if (RegExp(r'\b(dv|dolby vision)\b').hasMatch(value)) {
    parts.add('DV');
  } else if (RegExp(r'\bhdr10\+\b').hasMatch(value)) {
    parts.add('HDR10+');
  } else if (RegExp(r'\bhdr10\b').hasMatch(value)) {
    parts.add('HDR10');
  } else if (RegExp(r'\bhdr\b').hasMatch(value)) {
    parts.add('HDR');
  }

  if (RegExp(r'\bremux\b').hasMatch(value)) {
    parts.add('REMUX');
  } else if (RegExp(r'\bblu-?ray\b').hasMatch(value)) {
    parts.add('BluRay');
  } else if (RegExp(r'\bweb-?dl\b').hasMatch(value)) {
    parts.add('WEB-DL');
  } else if (RegExp(r'\bweb-?rip\b').hasMatch(value)) {
    parts.add('WEBRip');
  } else if (RegExp(r'\bweb\b').hasMatch(value)) {
    parts.add('WEB');
  } else if (RegExp(r'\bhdtv\b').hasMatch(value)) {
    parts.add('HDTV');
  } else if (RegExp(r'\bdvd-?rip\b').hasMatch(value)) {
    parts.add('DVDRip');
  } else if (RegExp(r'\bbr-?rip\b').hasMatch(value)) {
    parts.add('BRRip');
  }

  return parts.join(' · ');
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
