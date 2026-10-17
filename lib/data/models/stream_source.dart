/// Fuente de reproducción unificada.
///
/// Todo lo que puede acabar en el reproductor (debrid, addon, scraper o
/// torrent) se representa con este tipo. Es lógica pura: sin Flutter, sin red
/// y sin conocimiento de la UI.
library;

/// De dónde sale la fuente.
enum SourceKind {
  /// Enlace servido por un servicio debrid (cacheado o resuelto).
  debrid,

  /// Enlace directo devuelto por un addon.
  addon,

  /// Enlace extraído de una página por un pack de scraping.
  scraper,

  /// Torrent P2P crudo (infoHash/magnet).
  torrent,
}

/// Cómo se localiza el contenido.
enum StreamLocator {
  /// URL HTTP/HLS reproducible tal cual.
  url,

  /// Magnet completo, con trackers incluidos.
  magnet,

  /// Solo el hash; el motor P2P tendrá que resolver metadata y trackers.
  infoHash,
}

/// Referencia a un subtítulo asociado a la fuente.
class SubtitleReference {
  final String id;
  final String url;
  final String language;
  final String? label;

  const SubtitleReference({
    required this.id,
    required this.url,
    required this.language,
    this.label,
  });

  @override
  String toString() => 'SubtitleReference($id, $language)';
}

/// Candidato de reproducción con todo lo necesario para rankearlo y abrirlo.
class StreamSource {
  /// Identidad estable dentro de la lista (para desempates deterministas).
  final String id;

  /// Proveedor que lo encontró (`torrentio`, `real-debrid`, …).
  final String providerId;

  /// Etiqueta visible del proveedor (`torrent`, `real-debrid ⚡`, …).
  final String providerName;

  final SourceKind kind;

  /// Nombre del release o del archivo.
  final String title;

  /// URL directa, si la hay.
  final String? url;

  final String? infoHash;

  /// Índice del archivo dentro del torrent, cuando el addon lo conoce.
  final int? fileIdx;

  final String? magnetUrl;

  final String? quality;

  final int? sizeBytes;

  final int? seeds;

  /// Disponibilidad instantánea en el servicio debrid.
  final bool isCached;

  /// Idiomas de audio normalizados (`es-419`, `es`, `en`, …).
  final Set<String> audioLanguages;

  /// Idiomas de subtítulos disponibles en la propia fuente.
  final Set<String> subtitleLanguages;

  /// Subtítulos externos ya referenciados por el proveedor.
  final List<SubtitleReference> subtitles;

  /// Cabeceras HTTP necesarias (Referer, User-Agent…).
  final Map<String, String> headers;

  final String? referer;

  /// True cuando la URL debe pasar por el proxy local.
  final bool needsProxy;

  /// Motivo por el que no se puede reproducir con la configuración actual.
  final String? unavailableReason;

  const StreamSource({
    required this.id,
    required this.providerId,
    required this.providerName,
    required this.kind,
    required this.title,
    this.url,
    this.infoHash,
    this.fileIdx,
    this.magnetUrl,
    this.quality,
    this.sizeBytes,
    this.seeds,
    this.isCached = false,
    this.audioLanguages = const {},
    this.subtitleLanguages = const {},
    this.subtitles = const [],
    this.headers = const {},
    this.referer,
    this.needsProxy = false,
    this.unavailableReason,
  });

  /// Forma de localizarlo, o `null` si el candidato no trae enlace.
  StreamLocator? get locator {
    if (url != null && url!.isNotEmpty) return StreamLocator.url;
    if (magnetUrl != null && magnetUrl!.isNotEmpty) return StreamLocator.magnet;
    if (infoHash != null && infoHash!.isNotEmpty) {
      return StreamLocator.infoHash;
    }
    return null;
  }

  bool get isDirect => locator == StreamLocator.url;

  /// Una URL directa siempre se puede abrir; un magnet solo si hay un
  /// resolvedor (debrid hoy, P2P más adelante) y no está marcado como no
  /// disponible.
  bool get isAvailable {
    if (isDirect) return true;
    if (locator == null) return false;
    return unavailableReason == null;
  }

  String get filesizeDisplay {
    final bytes = sizeBytes;
    if (bytes == null) return '';
    final gb = bytes / (1024 * 1024 * 1024);
    if (gb >= 1) return '${gb.toStringAsFixed(1)} GB';
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(0)} MB';
  }

  StreamSource copyWith({
    String? id,
    String? providerId,
    String? providerName,
    SourceKind? kind,
    String? title,
    String? url,
    String? infoHash,
    int? fileIdx,
    String? magnetUrl,
    String? quality,
    int? sizeBytes,
    int? seeds,
    bool? isCached,
    Set<String>? audioLanguages,
    Set<String>? subtitleLanguages,
    List<SubtitleReference>? subtitles,
    Map<String, String>? headers,
    String? referer,
    bool? needsProxy,
    String? unavailableReason,
  }) {
    return StreamSource(
      id: id ?? this.id,
      providerId: providerId ?? this.providerId,
      providerName: providerName ?? this.providerName,
      kind: kind ?? this.kind,
      title: title ?? this.title,
      url: url ?? this.url,
      infoHash: infoHash ?? this.infoHash,
      fileIdx: fileIdx ?? this.fileIdx,
      magnetUrl: magnetUrl ?? this.magnetUrl,
      quality: quality ?? this.quality,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      seeds: seeds ?? this.seeds,
      isCached: isCached ?? this.isCached,
      audioLanguages: audioLanguages ?? this.audioLanguages,
      subtitleLanguages: subtitleLanguages ?? this.subtitleLanguages,
      subtitles: subtitles ?? this.subtitles,
      headers: headers ?? this.headers,
      referer: referer ?? this.referer,
      needsProxy: needsProxy ?? this.needsProxy,
      unavailableReason: unavailableReason ?? this.unavailableReason,
    );
  }

  @override
  String toString() =>
      'StreamSource($id, ${kind.name}, ${locator?.name ?? 'none'}, '
      'audio: $audioLanguages)';
}
