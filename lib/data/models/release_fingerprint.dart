/// Huella estable de un release: lo que identifica el fichero, no el enlace con
/// el que se abrió.
///
/// Un enlace de debrid caduca y un magnético puede llevar trackers de sesión;
/// lo que no cambia es el proveedor, el `infoHash`, el índice del fichero dentro
/// del torrent y la calidad. Con esa huella, reabrir el mismo magnet otro día
/// reconoce el mismo release y un pack de temporada distingue sus episodios.
library;

/// Identificador de release a partir de sus datos.
///
/// [providerId] es quien lo encontró (`torrentio`, `comet`, …); [infoHash] el
/// hash del torrent; [fileIdx] el fichero dentro del torrent; [quality] la
/// etiqueta que anuncia el addon.
String releaseSourceId({
  required String providerId,
  String? infoHash,
  int? fileIdx,
  String? quality,
}) {
  final provider = providerId.trim().toLowerCase();
  final hash = infoHash?.trim().toLowerCase();
  if (hash != null && hash.isNotEmpty) {
    final index = fileIdx == null ? '-' : '$fileIdx';
    return _withQuality('torrent:$provider:$hash:f$index', quality);
  }
  // Sin hash no hay torrent: la identidad sólo puede salir una URL directa.
  return _withQuality('release:$provider', quality);
}

/// Huella de una fuente ya construida.
///
/// Para un enlace directo se usan host y ruta, nunca la query: los addons firman
/// la URL con tokens que cambian en cada petición, y con ellos la huella sería
/// distinta cada vez.
String releaseSourceIdFrom({
  required String providerId,
  String? infoHash,
  int? fileIdx,
  String? quality,
  String? url,
}) {
  final hash = infoHash?.trim();
  if (hash != null && hash.isNotEmpty) {
    return releaseSourceId(
      providerId: providerId,
      infoHash: hash,
      fileIdx: fileIdx,
      quality: quality,
    );
  }
  final uri = url == null ? null : Uri.tryParse(url.trim());
  final location = uri == null || uri.host.isEmpty
      ? (url ?? '').trim().toLowerCase()
      : '${uri.host.toLowerCase()}${uri.path}';
  return _withQuality(
    'direct:${providerId.trim().toLowerCase()}:$location',
    quality,
  );
}

String _withQuality(String base, String? quality) {
  final tag = quality?.trim().toLowerCase();
  return tag == null || tag.isEmpty ? base : '$base:$tag';
}
