/// Decisión de reproducción a partir de una [StreamSource] directa.
///
/// Vive fuera de la UI para poder probar la frontera que dejaba inutilizables
/// las fuentes de addon: las cabeceras y `needsProxy` tienen que seguir viajando
/// desde el selector hasta el reproductor. Lógica pura: sin Flutter, sin red.
library;

import '../models/stream_source.dart';

/// Cabeceras HTTP que el proxy debe aplicar al abrir [source].
///
/// `Referer` puede llegar en el mapa de `proxyHeaders` o en su campo propio; se
/// unifica en una sola entrada sin duplicar por mayúsculas/minúsculas. Los
/// valores vacíos se descartan. Un `source` nulo (por ejemplo una URL ya
/// resuelta por debrid) no arrastra cabeceras del addon.
Map<String, String> playbackHeaders(StreamSource? source) {
  if (source == null) return const {};

  final headers = <String, String>{};
  for (final entry in source.headers.entries) {
    final name = entry.key.trim();
    final value = entry.value.trim();
    if (name.isEmpty || value.isEmpty) continue;
    headers[name] = value;
  }

  final referer = source.referer?.trim();
  if (referer != null && referer.isNotEmpty) {
    headers.removeWhere((key, _) => key.toLowerCase() == 'referer');
    headers['Referer'] = referer;
  }
  return headers;
}

/// True cuando la URL debe servirse desde el proxy local: el origen exige
/// cabeceras o el addon marcó la fuente como `notWebReady`.
bool shouldProxyStream(StreamSource? source) {
  if (source == null) return false;
  return source.needsProxy || playbackHeaders(source).isNotEmpty;
}
